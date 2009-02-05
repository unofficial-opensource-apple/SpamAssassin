/*
 *  Copyright (C) 2002 Nigel Horne <njh@bandsman.co.uk>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *
 * $Log: text.c,v $
 * Revision 1.5  2004/11/30 17:30:00  dasenbro
 * Upgrade to Clam AntiVirus 0.80
 *
 * Revision 1.10  2004/08/22 10:34:24  nigelhorne
 * Use fileblob
 *
 * Revision 1.9  2004/08/21 11:57:57  nigelhorne
 * Use line.[ch]
 *
 * Revision 1.8  2004/07/20 14:35:29  nigelhorne
 * Some MYDOOM.I were getting through
 *
 * Revision 1.7  2004/06/22 04:08:02  nigelhorne
 * Optimise empty lines
 *
 * Revision 1.6  2004/05/05 09:37:52  nigelhorne
 * Removed textClean - not needed in clamAV
 *
 * Revision 1.5  2004/03/25 22:40:46  nigelhorne
 * Removed even more calls to realloc and some duplicated code
 *
 * Revision 1.4  2004/02/26 13:26:34  nigelhorne
 * Handle spaces at the end of uuencoded lines
 *
 */

static	char	const	rcsid[] = "$Id: text.c,v 1.5 2004/11/30 17:30:00 dasenbro Exp $";

#if HAVE_CONFIG_H
#include "clamav-config.h"
#endif

#include <stdlib.h>
#if	C_DARWIN
#include <sys/types.h>
#include <sys/malloc.h>
#else
#ifdef HAVE_MALLOC_H /* tk: FreeBSD-CURRENT doesn't support malloc.h */
#ifndef	C_BSD	/* BSD now uses stdlib.h */
#include <malloc.h>
#endif
#endif
#endif
#include <string.h>
#include <ctype.h>
#include <assert.h>
#include <stdio.h>

#include "line.h"
#include "mbox.h"
#include "blob.h"
#include "text.h"
#include "others.h"

void
textDestroy(text *t_head)
{
	while(t_head) {
		text *t_next = t_head->t_next;
		if(t_head->t_line)
			lineUnlink(t_head->t_line);
		free(t_head);
		t_head = t_next;
	}
}

/*
 * Remove trailing spaces from the lines and trailing blank lines
 */
text *
textClean(text *t_head)
{
#if	0	/* not needed in ClamAV */
	text *t_lastnonempty = NULL, *t_ret;

	while(t_head) {
		char *line = t_head->t_text;
		const size_t len = strlen(line);
		int uuencoded = 0;

		if((len > 0) && !uuencoded) {
			int last = len;

			if((strncasecmp(line, "begin ", 6) == 0) &&
			   (isdigit(line[6])) &&
			   (isdigit(line[7])) &&
			   (isdigit(line[8])) &&
			   (line[9] == ' '))
				uuencoded = 1;
			else
				/*
				 * Don't remove trailing spaces since that may
				 * break uuencoded files
				 */
				while((--last >= 0) && isspace(line[last]))
					;
			if(++last > 0) {
				t_lastnonempty = t_head;
				if(last < len) {
					line[last] = '\0';
					t_head->t_text = cli_realloc(line, ++last);
				}
			} else {
				t_head->t_text = cli_realloc(line, 1);
				t_head->t_text[0] = '\0';
			}
		}
		t_head = t_head->t_next;
	}

	if(t_lastnonempty == NULL)
		return(NULL);	/* empty message I presume */

	t_ret = t_lastnonempty;
	t_lastnonempty = t_lastnonempty->t_next;

	while(t_lastnonempty) {
		text *t_next = t_lastnonempty->t_next;

		assert(strlen(t_lastnonempty->t_text) == 0);

		free(t_lastnonempty->t_text);
		free(t_lastnonempty);

		t_lastnonempty = t_next;
	}

	t_ret->t_next = NULL;

	return t_ret;
#else
	return t_head;
#endif
}

/* Clone the current object */
text *
textCopy(const text *t_head)
{
	text *first = NULL, *last = NULL;

	while(t_head) {
		if(first == NULL)
			last = first = (text *)cli_malloc(sizeof(text));
		else {
			last->t_next = (text *)cli_malloc(sizeof(text));
			last = last->t_next;
		}

		assert(last != NULL);

		if(t_head->t_line)
			last->t_line = lineLink(t_head->t_line);
		else
			last->t_line = NULL;

		t_head = t_head->t_next;
	}

	if(first)
		last->t_next = NULL;

	return first;
}

/* Add a copy of a text to the end of the current object */
text *
textAdd(text *t_head, const text *t)
{
	text *ret;

	if(t_head == NULL)
		return textCopy(t);

	if(t == NULL)
		return t_head;

	ret = t_head;

	while(t_head->t_next)
		t_head = t_head->t_next;

	while(t) {
		t_head->t_next = (text *)cli_malloc(sizeof(text));
		t_head = t_head->t_next;

		assert(t_head != NULL);

		if(t->t_line)
			t_head->t_line = lineLink(t->t_line);
		else
			t_head->t_line = NULL;

		t = t->t_next;
	}

	t_head->t_next = NULL;

	return ret;
}

/*
 * Add a message's content to the end of the current object
 */
text *
textAddMessage(text *aText, message *aMessage)
{
	assert(aMessage != NULL);

	if(messageGetEncoding(aMessage) == NOENCODING)
		return textAdd(aText, messageGetBody(aMessage));
	else {
		text *anotherText = messageToText(aMessage);

		if(aText) {
			aText = textAdd(aText, anotherText);
			textDestroy(anotherText);
			return aText;
		}
		return anotherText;
	}
}

/*
 * Transfer the contents of the text into a blob
 * The caller must free the returned blob if b is NULL
 */
blob *
textToBlob(const text *t, blob *b)
{
	const text *t1;
	size_t s = 0;

	assert(t != NULL);

	if(b == NULL) {
		b = blobCreate();

		if(b == NULL)
			return NULL;
	}

	for(t1 = t; t1; t1 = t1->t_next)
		if(t1->t_line)
			s += strlen(lineGetData(t1->t_line)) + 1;
		else
			s++;

	blobGrow(b, s);

	do {
		if(t->t_line) {
			const char *l = lineGetData(t->t_line);

			blobAddData(b, (unsigned char *)l, strlen(l));
		}
		blobAddData(b, (unsigned char *)"\n", 1);
	} while((t = t->t_next) != NULL);

	blobClose(b);

	return b;
}

fileblob *
textToFileblob(const text *t, fileblob *fb)
{
	assert(fb != NULL);
	assert(t != NULL);

	if(fb == NULL) {
		fb = fileblobCreate();

		if(fb == NULL)
			return NULL;
	}

	do {
		if(t->t_line) {
			const char *l = lineGetData(t->t_line);

			fileblobAddData(fb, (unsigned char *)l, strlen(l));
		}
		fileblobAddData(fb, (unsigned char *)"\n", 1);
	} while((t = t->t_next) != NULL);

	return fb;
}
