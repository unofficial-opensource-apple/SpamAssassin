#
# xbs-compatible wrapper Makefile for SpamAssassin
#

PROJECT=SpamAssassin

SHELL := /bin/sh

# Sane defaults, which are typically overridden on the command line.
SRCROOT=
OBJROOT=$(SRCROOT)
SYMROOT=$(OBJROOT)
DSTROOT=/usr/local
RC_ARCHS=
CFLAGS=-Os $(RC_CFLAGS)

# Configuration values we customize
#

PROJECT_NAME=SpamAssassin

AMAVIS_DIR=/private/var/amavis
VIRUS_MAILS_DIR=/private/var/virusmails
ETCDIR=/private/etc
ETC_SPAMA_DIR=/private/etc/mail/spamassassin
ETC_CLAMAV_DIR=/private/etc/spam/clamav
SHAREDIR=/usr/share/man
SETUPEXTRASDIR=SetupExtras
SASCRIPTSDIR=/System/Library/ServerSetup/SetupExtras
PERL_VER=`perl -V:version | sed -n -e "s/[^0-9.]*\([0-9.]*\).*/\1/p"`

STRIP=/usr/bin/strip

# Clam Antivirus config
#

CLAMAV_CONFIG= \
	--prefix=/ \
	--exec-prefix=/usr \
	--bindir=/usr/bin \
	--sbindir=/usr/sbin \
	--libexecdir=/usr/libexec \
	--datadir=/usr/share/clamav \
	--sysconfdir=/private/etc/spam/clamav \
	--sharedstatedir=/user/share/clamav/com \
	--localstatedir=/private/var/clamav \
	--libdir=/usr/lib \
	--includedir=/usr/share/clamav/include \
	--oldincludedir=/usr/share/clamav/include \
	--infodir=/usr/share/clamav/info \
	--mandir=/usr/share/man \
	--enable-milter \
	--with-dbdir=/private/var/clamav \
	--disable-shared \
	--with-user=0 \
	--with-group=0 \
	--enable-static

# Perl Modules
#

MODULES = Archive-Tar-1.08 Archive-Zip-1.10 Compress-Zlib-1.33 Convert-TNEF-0.17 \
		Digest-HMAC-1.01 Digest-SHA1-2.10 HTML-Parser-3.36 HTML-Tagset-3.03 \
		IO-stringy-2.109 Mail-Audit-2.1 Mail-POP3Client-2.16 Mail-SPF-Query-1.996 \
		MailTools-1.62 Net-DNS-0.47 Net-Ping-2.31 Net-Server-0.87 Unix-Syslog-0.99 \
		MIME-tools-5.411 URI-1.30
# URI-1.30 razor-agents-2.40

WITH_CCCDLFLAGS = Convert-UUlib-1.03

# DB_File-1.808 - fails with
#  ld: /usr/local/BerkeleyDB/lib/libdb.a(env_open.o) has local relocation entries in non-writable section (__TEXT,__text)
# razor-agents-2.40
#  BEGIN failed--compilation aborted at blib/script/razor-client line 21.

# These includes provide the proper paths to system utilities
#

include $(MAKEFILEPATH)/pb_makefiles/platform.make
include $(MAKEFILEPATH)/pb_makefiles/commands-$(OS).make

default:: make_sa make_modules make_clamav

install :: make_clamav_install make_amavisd_install make_sa_install make_modules_install

install_debug :: make_sasl_install make_imap_install

installhdrs :
	$(SILENT) $(ECHO) "No headers to install"

installsrc :
	[ ! -d $(SRCROOT)/$(PROJECT) ] && mkdir -p $(SRCROOT)/$(PROJECT)
	tar cf - . | (cd $(SRCROOT) ; tar xfp -)
	find $(SRCROOT) -type d -name CVS -print0 | xargs -0 rm -rf

make_sa :
	$(SILENT) $(ECHO) "-------------- Spam Assassin --------------"
	$(SILENT) ($(CD) "$(SRCROOT)/SpamAssassin" && perl Makefile.PL PREFIX=/ DESTDIR=$(DSTROOT))
	$(SILENT) ($(CD) "$(SRCROOT)/SpamAssassin" && make)

make_clamav :
	$(SILENT) $(ECHO) "-------------- Clam AV --------------"
	$(SILENT) ($(CD) "$(SRCROOT)/clamav" && /usr/bin/gnutar -xzpf clamav-0.70-rc.tar.gz)
	$(SILENT) ($(CD) "$(SRCROOT)/clamav/clamav" && ./configure $(CLAMAV_CONFIG))
	$(SILENT) ($(CD) "$(SRCROOT)/clamav/clamav" && make)

make_clamav_install :  $(DSTROOT)$(ETCDIR) $(DSTROOT)$(ETC_CLAMAV_DIR)
	$(SILENT) $(ECHO) "-------------- Clam AV --------------"
	$(SILENT) ($(CD) "$(SRCROOT)/clamav" && /usr/bin/gnutar -xzpf clamav-0.70-rc.tar.gz)
	$(SILENT) if [ -e "$(SRCROOT)/clamav/clamav/Makefile" ]; then\
		$(SILENT) ($(CD) "$(SRCROOT)/clamav/clamav" && make distclean) \
	fi
	$(SILENT) ($(CD) "$(SRCROOT)/clamav/clamav" && ./configure $(CLAMAV_CONFIG) CFLAGS="$(RC_CFLAGS)")
	$(SILENT) ($(CD) "$(SRCROOT)/clamav/clamav" && make "DESTDIR=$(SRCROOT)/Extra/dest" install)
	$(SILENT) ($(CD) "$(SRCROOT)/Extra/dest" && $(CP) -rpf * "$(DSTROOT)")
	$(SILENT) ($(CD) "$(SRCROOT)/Extra/etc" && $(CP) -rpf *.conf "$(DSTROOT)$(ETC_CLAMAV_DIR)/")
	$(SILENT) ($(CD) "$(DSTROOT)" && /usr/sbin/chown -R root:wheel *)
	$(SILENT) (/usr/sbin/chown -R clamav:clamav "$(DSTROOT)$(ETC_CLAMAV_DIR)")
	$(SILENT) ($(RM) -rf "$(SRCROOT)/clamav/clamav")
	$(SILENT) ($(RM) -rf "$(SRCROOT)/Extra/dest/usr")
	$(SILENT) ($(RM) -rf "$(SRCROOT)/Extra/dest/private")

make_amavisd_install : $(DSTROOT)$(AMAVIS_DIR) $(DSTROOT)$(VIRUS_MAILS_DIR)
	$(SILENT) $(ECHO) "-------------- Amavisd --------------"
	$(SILENT) ($(CP) "$(SRCROOT)/amavisd/amavisd.conf" "$(DSTROOT)/private/etc/")
	$(SILENT) (/usr/sbin/chown root "$(DSTROOT)/private/etc/amavisd.conf")
	$(SILENT) (/bin/chmod 644 "$(DSTROOT)/private/etc/amavisd.conf")
	$(SILENT) ($(CP) "$(SRCROOT)/amavisd/amavisd" "$(DSTROOT)/usr/bin/")
	$(SILENT) (/usr/sbin/chown root "$(DSTROOT)/usr/bin/amavisd")
	$(SILENT) (/bin/chmod 755 "$(DSTROOT)/usr/bin/amavisd")
	$(SILENT) (/usr/sbin/chown -R clamav:clamav "$(DSTROOT)$(AMAVIS_DIR)")
	$(SILENT) (/bin/chmod 750 "$(DSTROOT)$(AMAVIS_DIR)")
	$(SILENT) (/usr/sbin/chown -R clamav:clamav "$(DSTROOT)$(VIRUS_MAILS_DIR)")
	$(SILENT) (/bin/chmod 750 "$(DSTROOT)$(VIRUS_MAILS_DIR)")
	$(SILENT) (/bin/echo "\n" > "$(DSTROOT)$(AMAVIS_DIR)/whitelist_sender")
	$(SILENT) (/usr/sbin/chown -R clamav:clamav "$(DSTROOT)$(AMAVIS_DIR)/whitelist_sender")
	$(SILENT) (/bin/chmod 644 "$(DSTROOT)$(AMAVIS_DIR)/whitelist_sender")
	$(SILENT) ($(CP) "$(SRCROOT)/Extra/usr/share/man/man8/"* "$(DSTROOT)/usr/share/man/man8/")

make_sa_install : $(DSTROOT)$(SHAREDIR) $(DSTROOT)$(ETCDIR) $(DSTROOT)$(ETC_SPAMA_DIR)
	$(SILENT) $(ECHO) "-------------- Spam Assassin --------------"
	$(SILENT) ($(CD) "$(SRCROOT)/SpamAssassin" && perl Makefile.PL PREFIX=/ DESTDIR=$(DSTROOT))
	$(SILENT) ($(CD) "$(SRCROOT)/SpamAssassin" && make CFLAGS="$(RC_CFLAGS)" install)
	$(SILENT) ($(CD) "$(DSTROOT)/etc" && $(CP) -rpf * $(DSTROOT)$(ETCDIR))
	$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/etc")
	$(SILENT) ($(CD) "$(DSTROOT)/man" && $(CP) -rpf * "$(DSTROOT)$(SHAREDIR)")
	$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/man")
	$(SILENT) if [ -d "$(DSTROOT)/lib/perl5/site_perl/" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)/lib/perl5/site_perl/" && $(CP) -rpf * "$(DSTROOT)/System/Library/Perl/"); \
	fi
	$(SILENT) if [ -d "$(DSTROOT)/lib" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/lib"); \
	fi
	$(SILENT) if [ -d "$(DSTROOT)/Library/Perl" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)/Library/Perl/" && $(CP) -rpf * "$(DSTROOT)/System/Library/Perl/"); \
	fi
	$(SILENT) if [ -d "$(DSTROOT)/Library/Perl" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/Library"); \
	fi
	$(SILENT) ($(STRIP) -S $(DSTROOT)/usr/bin/spamd)
	$(SILENT) ($(STRIP) -S $(DSTROOT)/usr/bin/spamc)
	$(SILENT) ($(CD) "$(SRCROOT)/SpamAssassin" && make clean)
	$(SILENT) ($(CD) "$(SRCROOT)" && $(RM) ./SpamAssassin/Makefile.old)
	$(SILENT) ($(CP) "$(SRCROOT)/Extra/etc/mail/spamassassin/local.cf" "$(DSTROOT)$(ETC_SPAMA_DIR)")
	$(SILENT) $(ECHO) "---- Building Spam Assassin complete."

make_modules :
	$(SILENT) $(ECHO) "-------------- Perl Modules ---------------"
	for perl_mod in $(MODULES); \
	do \
		$(CD) "$(SRCROOT)/Perl/$$perl_mod" && perl Makefile.PL PREFIX=/ DESTDIR=$(DSTROOT) || exit 1; \
	done

make_modules_install :
	$(SILENT) $(ECHO) "-------------- Perl Modules ---------------"
	$(SILENT) $(ECHO) "Perl Version: $(PERL_VER)"
	for perl_mod in $(MODULES); \
	do \
		$(CD) "$(SRCROOT)/Perl/$$perl_mod" && perl Makefile.PL PREFIX=/ && make DESTDIR=$(DSTROOT) CFLAGS="$(RC_CFLAGS)" OTHERLDFLAGS="$(RC_CFLAGS)" install || exit 1; \
	done
	for perl_mod in $(MODULES); \
	do \
		$(CD) "$(SRCROOT)/Perl/$$perl_mod" && make distclean || exit 1; \
	done
	for perl_mod in $(WITH_CCCDLFLAGS); \
	do \
		$(CD) "$(SRCROOT)/Perl/$$perl_mod" && perl Makefile.PL PREFIX=/ && make DESTDIR=$(DSTROOT) CCCDLFLAGS="$(RC_CFLAGS)" OTHERLDFLAGS="$(RC_CFLAGS)" install || exit 1; \
	done
	for perl_mod in $(WITH_CCCDLFLAGS); \
	do \
		$(CD) "$(SRCROOT)/Perl/$$perl_mod" && make distclean || exit 1; \
	done
	$(SILENT) if [ -d "$(DSTROOT)/lib/perl5/site_perl/" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)/lib/perl5/site_perl/" && $(CP) -rpf * "$(DSTROOT)/System/Library/Perl/"); \
	fi
	$(SILENT) if [ -d "$(DSTROOT)/lib" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/lib"); \
	fi
	$(SILENT) if [ -d "$(DSTROOT)/Library/Perl" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)/Library/Perl/" && $(CP) -rpf * "$(DSTROOT)/System/Library/Perl/"); \
	fi
	$(SILENT) if [ -d "$(DSTROOT)/Library/Perl" ]; then\
		$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/Library"); \
	fi
	$(SILENT) ($(CD) "$(DSTROOT)/man" && $(CP) -rpf * $(DSTROOT)$(SHAREDIR))
	$(SILENT) ($(CD) "$(DSTROOT)" && $(RM) -rf "$(DSTROOT)/man")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/Archive" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/Archive")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/Convert" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/Convert")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/Digest" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/Digest")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/HTML" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/HTML")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/IO" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/IO")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/Mail" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/Mail")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/Net" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/Net")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/auto" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/auto")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/MIME" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/MIME")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/URI" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/URI")
	$(SILENT) ($(CP) -rpf "$(DSTROOT)/System/Library/Perl/URI.pm" "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/System/Library/Perl/URI.pm")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Digest/SHA1/SHA1.bundle")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/HTML/Parser/Parser.bundle")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Net/DNS/DNS.bundle")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Compress/Zlib/Zlib.bundle")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Convert/UUlib/UUlib.bundle")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Unix/Syslog/Syslog.bundle")
	$(SILENT) ($(ECHO) "bii" >> "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Digest/SHA1/SHA1.bs")
	$(SILENT) ($(ECHO) "bii" >> "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Convert/UUlib/UUlib.bs")
	$(SILENT) ($(ECHO) "bii" >> "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/HTML/Parser/Parser.bs")
	$(SILENT) ($(ECHO) "bii" >> "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Net/DNS/DNS.bs")
	$(SILENT) ($(ECHO) "bii" >> "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Compress/Zlib/Zlib.bs")
	$(SILENT) ($(ECHO) "bii" >> "$(DSTROOT)/System/Library/Perl/$(PERL_VER)/darwin-thread-multi-2level/auto/Unix/Syslog/Syslog.bs")
	$(SILENT) ($(CD) "$(DSTROOT)" && /usr/bin/chgrp -R wheel *)
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/usr/bin/clamdscan")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/usr/bin/clamscan")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/usr/bin/freshclam")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/usr/bin/sigtool")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/usr/lib/libclamav.a")
	$(SILENT) ($(RM) -rf "$(DSTROOT)/usr/lib/libclamav.la")
	$(SILENT) ($(STRIP) -S "$(DSTROOT)/usr/sbin/clamd")
	$(SILENT) (/bin/chmod 755 "$(DSTROOT)/private/var/clamav")
	$(SILENT) (/bin/chmod 644 "$(DSTROOT)/private/var/clamav/daily.cvd")
	$(SILENT) (/bin/chmod 644 "$(DSTROOT)/private/var/clamav/main.cvd")
	$(SILENT) ($(RM) -rf "$(SRCROOT)/clamav")
	$(SILENT) $(ECHO) "---- Building Perl Modules complete."

.PHONY: clean installhdrs installsrc build install 

$(DSTROOT) :
	$(SILENT) $(MKDIRS) $@

$(DSTROOT)$(ETCDIR) :
	$(SILENT) $(MKDIRS) $@

$(DSTROOT)$(ETC_CLAMAV_DIR) :
	$(SILENT) $(MKDIRS) $@

$(DSTROOT)$(ETC_SPAMA_DIR) :
	$(SILENT) $(MKDIRS) $@

$(DSTROOT)$(SHAREDIR) :
	$(SILENT) $(MKDIRS) $@

$(DSTROOT)$(AMAVIS_DIR) :
	$(SILENT) $(MKDIRS) $@

$(DSTROOT)$(VIRUS_MAILS_DIR) :
	$(SILENT) $(MKDIRS) $@
