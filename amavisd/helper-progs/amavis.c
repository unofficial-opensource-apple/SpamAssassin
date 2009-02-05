#ifndef lint
static char *RCSid() { return RCSid("$Id: amavis.c,v 1.1 2004/04/19 17:08:44 dasenbro Exp $"); }
#endif

/*
 * client for amavisd
 *
 * Author: Geoff Winkless <gwinkless@users.sourceforge.net>
 * Additional work and patches by:
 *   Gregory Ade
 *   Thomas Biege
 *   Pierre-Yves Bonnetain
 *   Ricardo M. Ferreira
 *   Lars Hecking
 *   Rainer Link
 *   Julio Sanchez
 *   Mark Martinec (2002-07-30, don't pass LDA args to amavisd,
 *                  call LDA directly)
 *
 */

/*
 * Add some copyright notice here ...
 *
 * Usage: amavis sender recipient [recipient ...] [-- lda [lda-args]]
 *
 */

#include "config.h"

#define BUFFLEN 8192
/* Must be the same as the buffer length for recv() in amavisd */
#define SOCKBUFLEN 8192

#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>
#include <sys/wait.h>
#include <libgen.h>

#define D_TEMPLATE "/amavis-XXXXXXXX"
#define F_TEMPLATE "/email.txt"

#define DBG_NONE  0
#define DBG_INFO  1
#define DBG_WARN  2
#define DBG_FATAL 4

#define DBG_ALL     (DBG_FATAL | DBG_WARN | DBG_INFO)

static struct utsname myuts;

/* Don't debug by default */
static const int debuglevel = DBG_NONE;
/* static const int debuglevel = DBG_ALL; */
static const char *mydebugfile = RUNTIME_DIR "/amavis.client";

/* temp dir where mail message is stored */
static char *dir_name;
/* temp file where mail message is stored */
static char *atmpfile;

static size_t mystrlcpy(char *, const char *, size_t);
static void mydebug(const int, const char *, ...);
static char *mymktempdir(char *);
static char *next_envelope(char *);
static void amavis_cleanup(void);

static size_t
mystrlcpy(char *dst, const char *src, size_t size)
{
    size_t src_l = strlen(src);
    if(src_l < size) {
	memcpy(dst, src, src_l + 1);
    } else if(size) {
	memcpy(dst, src, size - 1);
	dst[size - 1] = '\0';
    }
    return src_l;
}

static void
mydebug(const int level, const char *fmt, ...)
{
    FILE *f = NULL;
    time_t tmpt;
    char *timestamp;
    int rv;
    va_list ap;

    if (!(level & debuglevel))
	return;

    /* Set up debug file */
    if (mydebugfile && (f = fopen(mydebugfile, "a")) == NULL) {
	fprintf(stderr, "error opening '%s': %s\n", mydebugfile, strerror(errno));
	return;
    }

    tmpt = time(NULL);
    timestamp = ctime(&tmpt);
    /* A 26 character string according ctime(3c)
     * we cut off the trailing \n\0 */
    timestamp[24] = 0;
    rv = fprintf(f, "%s %s amavis(client)[%ld]: ",
    	timestamp, (myuts.nodename ? myuts.nodename : "localhost"), (long) getpid());
    if (rv < 0)
	perror("error writing (fprintf) to debug file");

    va_start(ap, fmt);
    rv = vfprintf(f, fmt, ap);
    va_end(ap);
    if (rv < 0)
	perror("error writing (vfprintf) to debug file");

    rv = fputc('\n', f);
    if (rv < 0)
	perror("error writing (fputc) to debug file");
    rv = fclose(f);
    if (rv < 0)
	perror("error closing debug file f");
}


static char *
mymktempdir(char *s)
{
#ifdef HAVE_MKDTEMP
    return mkdtemp(s);
#else
    char *stt;
    int count = 0;

    /* magic number alert */
    while (count++ < 20) {
# ifdef HAVE_MKTEMP
	stt = mktemp(s);
# else
	/* relies on template format */
	stt = strchr(s, '-') + 1;
	if (stt) {
	    /* more magic number alert */
	    snprintf(stt, strlen(s) - 1 - (stt - s), "%08d", lrand48() / 215);
	    stt = s;
	} else {
	    /* invalid template */
	    return NULL;
	}
# endif
	if (stt) {
	    if (!mkdir(s, S_IRWXU)) {
		return s;
	    } else {
		continue;
	    }
	}
    }
    return NULL;
#endif /* HAVE_MKDTEMP */
}

static void
amavis_cleanup(void)
{
    if (dir_name)
	free(dir_name);

    if (atmpfile)
	free(atmpfile);
}

static int
call_lda(int fdin, const char *path, char *const argv[])
{
    pid_t pid;
    int status;

    mydebug(DBG_INFO, "calling LDA: %s %s ...", path, argv[0]);

    fflush(stdout);
    fflush(stderr);
    pid = fork();
    if (pid < 0) {
	mydebug(DBG_FATAL, "Can't fork: %s", strerror(errno));
	return EX_TEMPFAIL;
    }
    if (!pid) {  /* child */
	int d = dup2(fdin,STDIN_FILENO);
	if (d < 0) {
	    fprintf(stderr, "dup2 %d failed: %s\n", fdin, strerror(errno));
	    exit(EX_TEMPFAIL);
	} else if (d != STDIN_FILENO) {
	    fprintf(stderr, "dup2 %d error to stdin (got %d)\n", fdin, d);
	    exit(EX_TEMPFAIL);
	}
	close(fdin);
	execv(path, argv);
	fprintf(stderr, "Can't exec LDA '%s': %s\n", path, strerror(errno));
	exit(EX_TEMPFAIL);
    }
    /* parent */
    if (waitpid(pid, &status, 0) < 0) {
	mydebug(DBG_FATAL, "Waiting for LDA child aborted: %s", strerror(errno));
	return EX_TEMPFAIL;
    }
    if (!WIFEXITED(status)) {
	if (WIFSIGNALED(status))
	    mydebug(DBG_FATAL, "LDA child died, signal: %d", WTERMSIG(status));
	else
	    mydebug(DBG_FATAL, "LDA child aborted, status: %d", status);
	return EX_TEMPFAIL;
    }
    return WEXITSTATUS(status);
}

/* Simple "protocol" */
const char _LDA = '\2';
const char _EOT = '\3';

/* take input from stdin as an email, with argv as sender and recipients
 * then pass it all to amavisd
 * TODO: sender/recipient parsing for qmail; see qmail-queue(8) for details
 */
int
main(int argc, char **argv)
{
    char *buff;			/* temp buffer for mail message */
    char xstat[8] = { 0 };
    struct sockaddr_un saddr;
    FILE *fout = NULL;
    int fd = 0;
    size_t rw = 0, msgsize = 0;
    int r, sock, i;		/* socket func return val, socket descriptor, index var */
    char retval;
    int ldaargs_ind = -1;
    int fdin;  /* keep the file open to be able to pass it on
		  to LDA even after unlinking */
    struct stat StatBuf;
#if !defined(HAVE_MKDTEMP) && !defined(HAVE_MKTEMP)
    int mypid = getpid();

    srand48(time(NULL) ^ (mypid + (mypid << 15)));
#endif

    atexit(amavis_cleanup);

    /* */
    uname(&myuts);

    /* Process args first */
    if (argc < 3) {
	mydebug(DBG_FATAL, "Insufficient number of arguments: %s", strerror(errno));
	exit(EX_TEMPFAIL);
    }

    umask(0077);

    /* */
    dir_name = malloc(strlen(RUNTIME_DIR) + strlen(D_TEMPLATE) + 1);
    if (dir_name == NULL) {
	mydebug(DBG_FATAL, "Failed to allocate memory for temp dir name: %s", strerror(errno));
	exit(EX_TEMPFAIL);
    }

    strcpy(dir_name, RUNTIME_DIR);
    strcat(dir_name, D_TEMPLATE);
    if (mymktempdir(dir_name) == NULL) {
	mydebug(DBG_FATAL, "Failed to create temp dir: %s", strerror(errno));
	exit(EX_TEMPFAIL);
    }

    if (lstat(dir_name, &StatBuf) < 0) {
	mydebug(DBG_FATAL, "%s: Error while trying lstat(%s): %s",
		argv[0], dir_name, strerror(errno));
	exit(EX_TEMPFAIL);
    }

    /* may be too restrictive for you, but's good to avoid problems */
    if (!S_ISDIR(StatBuf.st_mode) || StatBuf.st_uid != geteuid() ||
	StatBuf.st_gid != getegid() || !(StatBuf.st_mode & (S_IWUSR | S_IRUSR))) {
	mydebug(DBG_FATAL,
		"%s: Security Warning: %s must be a Directory and owned by "
		"User %d and Group %d and just read-/write-able by the User "
		" and noone else. Exit.", argv[0], dir_name, geteuid(), getegid());
	exit(EX_TEMPFAIL);
    }
    /* there is still a race condition here if RUNTIME_DIR is writeable by the attacker :-\ */

    atmpfile = malloc(strlen(dir_name) + strlen(F_TEMPLATE) + 1);
    if (atmpfile == NULL) {
	mydebug(DBG_FATAL, "Failed to allocate memory for temp file name: %s", strerror(errno));
	exit(EX_TEMPFAIL);
    }

    sprintf(atmpfile, "%s/email.txt", dir_name);

    buff = malloc(BUFFLEN);
    if (buff == NULL) {
	mydebug(DBG_FATAL, "Failed to allocate memory for read buffer: %s", strerror(errno));
	exit(EX_TEMPFAIL);
    }

    if ((fd = open(atmpfile, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR)) < 0 || (fout = fdopen(fd, "w")) == NULL)
	mydebug(DBG_FATAL, "failed to open a_tmp_file: %s", strerror(errno));

    while (!feof(stdin)) {
	rw = fread(buff, sizeof(char), BUFFLEN, stdin);
	fwrite(buff, sizeof(char), rw, fout);
	msgsize += rw;
    }
    fclose(fout);
    free(buff); buff = NULL;	/* will reuse later */
    mydebug(DBG_INFO, "size=%d", msgsize);

    /* keep the temporary file open, to be able to pass it on to LDA
       via STDIN even after unlinking the file and directory by amavisd-new */
    if ((fdin = open(atmpfile, O_RDONLY)) < 0)
	mydebug(DBG_FATAL, "error opening fdin '%s': %s", atmpfile, strerror(errno));

    r = (sock = socket(PF_UNIX, SOCK_STREAM, 0));
    if (r < 0)
	mydebug(DBG_FATAL, "failed to allocate socket: %s", strerror(errno));
    saddr.sun_family = AF_UNIX;
    mystrlcpy(saddr.sun_path, AMAVISD_SOCKET, sizeof(saddr.sun_path));
    if (r >= 0) {
	mydebug(DBG_INFO, "connect()");
	r = connect(sock, (struct sockaddr *) &saddr, sizeof(saddr));
	if (r < 0)
	    mydebug(DBG_FATAL, "failed to connect(): %s", strerror(errno));
    }
    if (r >= 0) {
	mydebug(DBG_INFO, "senddir() %s", dir_name);
	r = send(sock, dir_name, strlen(dir_name), 0);
	if (r < 0)
	    mydebug(DBG_FATAL, "failed to send() directory: %s", strerror(errno));
    }
    if (r >= 0) {
	r = recv(sock, &retval, 1, 0);
	if (r < 0)
	    mydebug(DBG_FATAL, "failed to recv() directory confirmation: %s",
		    strerror(errno));
    }
    if (r >= 0) {
	/* send envelope from */
	const char *sender = argv[1];
	int sender_l = strlen(sender);
	if (!sender_l) { sender = "<>"; sender_l = 2; }
	mydebug(DBG_INFO, "sendfrom() %s", sender);
	if (sender_l > SOCKBUFLEN) {
	    mydebug(DBG_WARN, "Sender too long (%d), truncated to %d characters", sender_l, SOCKBUFLEN);
	    sender_l = SOCKBUFLEN;
	}
	r = send(sock, sender, sender_l, 0);
	if (r < 0)
	    mydebug(DBG_FATAL, "failed to send() Sender: %s", strerror(errno));
	else if (r < sender_l)
	    mydebug(DBG_WARN, "failed to send() complete Sender, truncated to %d characters ", r);
    }
    if (r >= 0) {
	r = recv(sock, &retval, 1, 0);
	if (r < 0)
	    mydebug(DBG_FATAL, "failed to recv() ok for Sender info: %s",
		    strerror(errno));
    }
    if (r >= 0) {
	/* send recipients and lda/ldaargs if present */
	for (i = 2; i < argc; i++) {
	    int arg_l;
	    arg_l = strlen(argv[i]);
	    if (arg_l > SOCKBUFLEN) {
		mydebug(DBG_WARN, "Recipient too long (%d), truncated to %d characters", arg_l, SOCKBUFLEN);
		arg_l = SOCKBUFLEN;
	    }
	    if (strcmp(argv[i], "--") == 0) {
		ldaargs_ind = i;
		break;/* don' pass LDA args, we'll call LDA ourselves later! */
		mydebug(DBG_INFO, "sendlda() %s", argv[i]);
		r = send(sock, &_LDA, 1, 0);
	    } else {
		const char *recip = argv[i];
		if (!arg_l) { recip = "<>"; arg_l = 2; }
		mydebug(DBG_INFO, "sendto() %s", recip);
		/* mydebug(DBG_INFO, "sendlda/arg() %s", recip); */
		r = send(sock, recip, arg_l, 0);
		if (r >= 0 && r < arg_l)
		    mydebug(DBG_WARN, "failed to send() complete Recipient, truncated to %d characters", r);
	    }
	    if (r < 0) {
		mydebug(DBG_FATAL, "failed to send() Recipient: %s", strerror(errno));
		/* mydebug(DBG_FATAL, "failed to send/lda() recip info: %s", strerror(errno)); */
	    } else {
		r = recv(sock, &retval, 1, 0);
		if (r < 0) {
		    mydebug(DBG_FATAL, "failed to recv() ok for recip info: %s", strerror(errno));
		    /* mydebug(DBG_FATAL, "failed to recv() ok for recip/lda info: %s", strerror(errno)); */
		}
	    }
	}
    }
    if (r >= 0) {
	mydebug(DBG_INFO, "sendEOT()");
	r = send(sock, &_EOT, 1, 0);
	/* send "end of args" msg */
	if (r < 0)
	    mydebug(DBG_FATAL, "failed to send() EOT: %s", strerror(errno));
	else {
	    r = recv(sock, xstat, 6, 0);
	    mydebug(DBG_INFO, "received %s from daemon", xstat);
	    if (r < 0)
		mydebug(DBG_FATAL, "Failed to recv() final result: %s",
			strerror(errno));
	    else if (!r)
		mydebug(DBG_FATAL, "Failed to recv() final result: empty status string");
	    /* get back final result */
	}
    }
    close(sock);
    mydebug(DBG_INFO, "finished conversation");

    if (r < 0) {
	/* some point of the communication failed miserably - so give up */
	retval = EX_TEMPFAIL;
	mydebug(DBG_FATAL, "failing with EX_TEMPFAIL: %s", strerror(errno));
    } else {
	/* Protect against empty return string */
	retval = *xstat ? atoi(xstat) : EX_TEMPFAIL;
	mydebug(DBG_INFO, "retval is %d", retval);

	if (retval==99 && ldaargs_ind >= 0) {        /* DROP mail */
	    mydebug(DBG_INFO, "DROP mail");
	    retval = 0;     /* pretend it was delivered */
	} else if (retval==0 && ldaargs_ind >= 0) {  /* pass delivery to LDA */
	    char *path;
	    ldaargs_ind++;  /* step over "--" */
	    path = malloc(strlen(argv[ldaargs_ind]) + 1);
	    if (path == NULL)
		mydebug(DBG_FATAL, "Failed to allocate memory for temp dir name: %s", strerror(errno));
	    path = strcpy(path, argv[ldaargs_ind]);
	    argv[ldaargs_ind] = basename(path);
	    retval = call_lda(fdin, path, &argv[ldaargs_ind]);
	}
    }
    close(fdin);
    unlink(atmpfile);
    rmdir(dir_name);
    exit(retval);
}
