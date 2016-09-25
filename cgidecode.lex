%{
/* 
 * cgidecode decodes specified url-encoded or multipart-encoded variables 
 * supplied on stdin, whose names match those specified on the command line, and 
 * writes their names and values to stdout and optionally files in a directory.
 *
 * name=value is printed out on stdout if we're parsing url-encoded stuff.
 * If we're parsing multipart-encoded stuff, we just print out name, and
 * filename and/or content-type if it exists, and optionally write it
 * to an appropriately named subdirectory.
 *
 * $Id: cgidecode.lex,v 1.6 2015/11/06 15:32:35 jdd Exp $
 */

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include "patchlevel.h"

#define PROGNAME "cgidecode"

/* Input buffer sizes.  BUFFSIZE should be greater than LINESIZE */
#ifndef BUFFSIZE
#define BUFFSIZE 4096
#endif /* BUFFSIZE */
#ifndef LINESIZE
#define LINESIZE 1024
#endif /* LINESIZE */

/* default permissions for directories created */
#ifndef FILEMODE
#define FILEMODE 0700
#endif /* FILEMODE */

/* MIME text */
#define CONTENTDISP "Content-Disposition: form-data; name=\042"
#define CONTENTTYPE "Content-Type: "
#define CONTENTTYPE2 "content-type"

/* 
 * rfc2183 content-disposition parameters.  All others are ignored.
 */
char *cdparam[] = {
	"filename",
	"creation-date",
	"modification-date",
	"read-date",
	"size",
	NULL,
};

#define URL "url"
#define MULTIPART "multipart"
#define AUTODETECT "autodetect"

#ifndef YES
#define YES 1
#endif /* YES */

#ifndef NO
#define NO 0
#endif /* NO */

#ifndef MAYBE
#define MAYBE -1
#endif /* MAYBE */

char *progname, *t, *f, **vars, *dir=NULL, *cd=NULL;
FILE *fp;
int numvars, match=0, ismultipart=MAYBE;
u_long globalmax=0, bytes=0;

enum mode {
	name,
	body,
	error,
} parsing=name;

/* 
 * strmatch is strcmp if we're not using regular expressions, otherwise
 * it's a sort of regex extension of strcmp where the regular expression
 * is the first argument and the string being matched is the second).
 */
#ifdef REGEX
#define USAGE "Usage: "PROGNAME" [-V][-q][-C directory][-D directory][-e "URL"|"MULTIPART"|"AUTODETECT"] [varname-regex ...]\n"
#include <regex.h>
int strmatch(char *expression, char *str){
	regex_t re;
	regmatch_t pm;
	int rc;
	rc=regcomp(&re, expression, REG_EXTENDED|REG_NEWLINE);
	/* 
	 * We need to check to see that the entire string has been
	 * matched to the expression, not just part of it, hence we need
	 * to check the substring matching structure pm, to check
	 * the start and the end of the match, it's not enough to
	 * check the return of regexec, because it will indicate
	 * a match if expression matches a substring of str.
	 */
	if(0==rc && REG_NOMATCH==regexec(&re, str, (size_t)1, &pm, 0)){
		return(REG_NOMATCH); /* no match at all */
	} else if (0==pm.rm_so && strlen(str)==pm.rm_eo) {
		return(0);  /* matches the whole string */
	} else {
		return(REG_NOMATCH); /* matches a substring only */
	}
} 
#else /* !REGEX */
#define USAGE "Usage: "PROGNAME" [-V][-q][-C directory][-D directory][-e "URL"|"MULTIPART"|"AUTODETECT"] [varname ...]\n"
int strmatch(char *expression, char *str){
	return(strcmp(expression, str));
}
#endif /* !REGEX */

/*
 * Mgetc() - fgetc with checking for max bytes.
 */
int Mgetc(FILE *sm)
{
	int c;
	if(EOF!=(c=fgetc(sm))) bytes++;
	if(globalmax && bytes>globalmax){
		errno=ERANGE;
		return(EOF);
	} else return(c);
}

/*
 * Mgets() - fgets with checking for max bytes.
 */
char *Mgets(char *sg, int sz, FILE *sm)
{
	if(NULL!=fgets(sg,sz,sm)){
		bytes+=strlen(sg);
	}
	if(globalmax && bytes>globalmax){
		errno=ERANGE;
		return((char *)NULL);
	}
	return(sg);
}

/* cat() concatenates the string pt2 onto the end of the string pt1, returning 
 *	(possibly a new) pt1, (re|m)alloced as necessary.  pt1 is assumed to 
 *	be reallocable. 
 */
char *cat(char *pt1, char *pt2){
	/* concatenate pt2 onto the end of pt1, returning (possibly a new) pt1,
	 * (re|m)alloc as necessary. pt1 is assumed to be reallocable. */
	char *p1, *p2;

	if(NULL==(pt1=realloc((void *)pt1, strlen(pt1)+strlen(pt2)+1))){
		errno=ENOSPC;
		perror(progname);
		exit(1);
	}
	(void)strcat(pt1, pt2); 

	return(pt1);
}

/* 
 * Error() takes one string output and puts it out as a stderr message, then
 * exit(1)'s.
 */
void Error(char *msg){
	fprintf(stderr, "%s: %s\n", progname, msg);
	exit(1);
	/* NOTREACHED */
}

/* 
 * Perr() takes one string assumed to be a filename and runs perror, then
 * exit(1)'s.
 */
void Perr(char *fname){
	perror(fname);
	exit(1);
	/* NOTREACHED */
}

void cdparmwrite(char *cdsuffix, char *fn, char *parmname, char *value){
	/* given a suffix, a filename, and a content disposition parameter
	 * name and value, write out the value to a file named
	 * filename[suffix]/parametername, making the parent directory
	 * if needed.
	 */
	char *cddir, *cdparm; FILE *fp2;
	cddir=malloc(sizeof(char)); *cddir='\0';
	cddir=cat(cddir,fn);
	cddir=cat(cddir,cdsuffix);
	if(0>mkdir(cddir, FILEMODE)&&errno!=EEXIST) Perr(cddir);
	cdparm=malloc(sizeof(char)); *cdparm='\0';
	cdparm=cat(cdparm, cddir);
	cdparm=cat(cdparm, "/");
	cdparm=cat(cdparm, parmname);
	if(NULL==(fp2=fopen(cdparm,"w"))) Perr(f);
	if(0>fputs(value, fp2)) Perr(f);
	if(0>fclose(fp2)) Perr(f);
}

char *name2file(char *di, char *vn, char *cd){
	/* given a directory di, a variable name vn, and a 
	 * content disposition suffix cd, 
	 * for a file or directory named di/vn. 
	 * 1. If it is absent, return di/vn. 
	 * 2. If it is a file, change it to a directory and move the
	 * file that was there into di/vn/0, returning di/vn/1. 
	 * If cd exists and di/vn[cd] exists, then move it to di/vn/0[cd]
	 * 3. If it is a directory, return di/fn/N, where N is one greater 
	 * than the numerically largest filename that is a number. 
	 */
	struct stat sb;
	char *st;

	st=malloc(sizeof(char)); 
	*st='\0';

	st=cat(st,di);
	st=cat(st,"/");
	st=cat(st,vn);
	if(0==stat(st,&sb)){ /* file exists... */
		if(S_ISDIR(sb.st_mode)){
			/* ... and is a directory. */
			DIR *dr;
			struct dirent *de;
			int fnum=0;
			char fbuf[sizeof(de->d_name)];
			st=cat(st,"/");
			/* return di/vn/N, where N is numerically
			 * greatest filename in di/fn
			 */
			if(NULL==(dr=opendir(st))) Perr(st);
			errno=0;
			while(de=readdir(dr)){
				int i;
				i=atoi(de->d_name);
				if(i>fnum) fnum=i;
			}
			if(0!=errno) Perr(st);
			if(0>closedir(dr)) Perr(st);
			snprintf(fbuf, sizeof(de->d_name), "%d", fnum+1);
			st=cat(st, fbuf);
			return(st);
		} else if(S_ISREG(sb.st_mode)){
			/* ... and is a regular file. */
			/* mv di/vn to di/vn/0 and return di/vn/1
			 */
			char *f1, *f2;
			f1=malloc(sizeof(char)); *f1='\0';
			f1=cat(f1,st);
			f1=cat(f1," "); /* temporary fn that won't exist */
			if(0>rename(st,f1)) Perr(st);
			if(0>mkdir(st, (mode_t)FILEMODE)) Perr(st);
			f2=malloc(sizeof(char)); *f2='\0';
			f2=cat(f2,st);
			f2=cat(f2,"/0");
			if(0>rename(f1,f2)) Perr(f2);
			if(cd){
				char *c1, *c2;
				c1=malloc(sizeof(char)); *c1='\0';
				c1=cat(c1,st);
				c1=cat(c1,cd);
				c2=malloc(sizeof(char)); *c2='\0';
				c2=cat(c2,st);
				c2=cat(c2,"/0");
				c2=cat(c2,cd);
				if(0>rename(c1,c2)&&ENOENT!=errno) Perr(c2);
			}
			st=cat(st, "/1");
			return(st);
		} else {
			/* ... but is something odd */
			Error(st);
		}
	} else if(ENOENT==errno){
		/* file doesn't exist, return di/vn */
		return(st);	
	} else {
		Perr(st);
	}
	/* NOTREACHED */
}

void processname(){
	/* process the "name=" part of a urlencoded variable */
	/* variable name */
	if(parsing==name){
		int i;
		for(i=0;i<numvars;i++){
			if(0==strmatch(vars[i],t)){
				printf("%s=", t);
				if(dir) {
					f=name2file(dir, t, NULL);
					if(NULL==(fp=fopen(f,"w"))) Perr(f);
				}
				match++;
				break;
			}
		}	
		parsing=body;
	}
	t[0]=(char)0; 
}

void processvalue(){
	/* process the "=value" part of a urlencoded variable */
	if(parsing==body && match) {
		printf("%s\n", t); 
		if(dir){
			if(0>fputs(t, fp)) Perr(t);
			if(0>fclose(fp)) Perr(t);
			f[0]=(char)0;
		} 
	} 
	t[0]=(char)0;
	parsing=name;
	match=0;
}

void trimnl(char *b){
	/* trim (in place) any \r\n or \n from the end of 
	 * the specified string by replacing with \0
	 */
	if('\n'==b[strlen(b)-1]) b[strlen(b)-1]='\0';
	if('\r'==b[strlen(b)-1]) b[strlen(b)-1]='\0';
}


void multipart(){
	/* Process multipart-encoded data, not url-encoded; completely
	 * different parsing rules.  multipart-encoded looks like this:
	 *
	 * -----------------------------23281168279961
	 * Content-Disposition: form-data; name="name"
	 *
	 * defaulttext
	 * -----------------------------23281168279961
	 * Content-Disposition: form-data; name="user"
	 *
	 * defaulttext
	 * -----------------------------23281168279961
	 * Content-Disposition: form-data; name="myfile"; filename="disks1.ps"
	 * Content-Type: application/postscript
	 * %!PS-Adobe-3.0
	 * ...<possible binary contents here>...
	 * -----------------------------23281168279961
	 * Content-Disposition: form-data; name="thoughts"
	 * 
	 * defaultthoughts
	 * -----------------------------23281168279961--
	 *
	 */
	char buf[BUFFSIZE], headbuf[LINESIZE+2], *header, name[BUFFSIZE];
	int firsttime=1; /* first time through loop? */

	/* the header is the part that looks like this:
	 * "-----------------------------23281168279961".  We distinguish
	 * "header" from headbuf, which contains the header with a 
	 * preceeding cr/ln.  We need "headbuf" because when we're reading
	 * the otherwise binary contents of a file, we won't know that we've
	 * come to the end of the file until we see something like
	 * "\r\n-----------------------------23281168279961".
	 */
	headbuf[0]='\r'; headbuf[1]='\n'; headbuf[2]='\0'; 
	header=headbuf+2;
	if(NULL==Mgets(header,LINESIZE,stdin)) {
		if(ERANGE==errno) {
			Error("Maximum input size exceeded."); 
		} else {
			Error("Header expected, no header present.");
		}
	}
	trimnl(header); 
	while(1){
		int i, hdr, b;
		char *p, *h;
		/* appendix is for stuff after name in content-disposition,
		 * usually only for files.  We print it out after
	         */
		char *appendix; 

		if(firsttime) {
			firsttime=0;
		} else {
			/* next read is either "--" if final EOF, or
			 * a blank line if there is more to read 
			 */
			if(NULL==Mgets(buf, sizeof(buf), stdin)) {
				Error("Premature EOF.");
			}
			if(0==strcmp(buf, "--\r\n")){
				/* we should be all done.  Try to read
				 * some more and if we get anything, throw
				 * an error.
				 */
#ifdef EXTRADATAISERR
				if(NULL!=Mgets(buf,sizeof(buf),stdin)){
					Error("Unexpected trailing data.");
				}
#endif /* EXTRADATAISERR */
				exit(0);
			} else if(0!=strcmp(buf,"\r\n")) {
				Error("Unexpected appendage to header.");
			}
		}

		/* read content-disposition. */
		if(NULL==Mgets(buf, sizeof(buf), stdin)) {
			if(ERANGE==errno) {
				Error("Maximum input size exceeded."); 
			} else {
				Error("Content-Disposition expected.");
			}
		}
		trimnl(buf);
		t=buf+strlen(CONTENTDISP);
		if(0!=strncmp(buf,CONTENTDISP, strlen(CONTENTDISP))){
			Error("Malformed Content-disposition.");
		}
		if(NULL==(appendix=strchr(t, '\042'))) {
			Error("Missing trailing quotation mark.");
		}
		for(i=0;i<numvars;i++){
			if('\042'==(*appendix)) {
				*appendix='\0';
				appendix++;
			}
			if(0==strmatch(vars[i],t)){
				match++;
				if(';'==(*appendix)) appendix++;
				if(' '==(*appendix)) appendix++;
				if(dir) {
					f=name2file(dir, t, cd);
					if(NULL==(fp=fopen(f,"w"))) Perr(f);
				}
				if(appendix && *appendix){
					/* parse appendix for content disposition
					 * parameters, which according to rfc2183
					 * are one or more of "filename=", 
					 * "creation-date=", "modification-date=",
					 * "read-date=", or "size=", separated by
					 * semicolons.  
					 */
					char *n;
					printf("%s %s", t, appendix);
					for(n=strtok(appendix, ";");NULL!=n;n=strtok(NULL, ";")){
						char *eq=NULL, *q1=NULL, *q2=NULL, *v;
						for(;*n==' ';n++) ; /* skip leading spaces */
						if(NULL==(eq=strchr(n, '='))){
							/* no '=', do nothing */
							continue;
						}
						*eq='\0';
						if(NULL==(q1=strchr(eq+1, '"')) ||
							NULL==(q2=strrchr(eq+1, '"')) ||
							q1==q2){
							/* no "proper" quoting.
							 * start value after the '=',
							 * skipping any leading spaces
							 */
							q2=NULL;
							v=eq+1;
							for(;*v==' ';v++) ; /* skip leading spaces */
						} else {
							/* value starts at the first doublequote 
							 * and goes to the last one */
							*q2='\0';
							v=q1+1;
						}

						if(cd) cdparmwrite(cd, f, n, v);
						/* restore = and " so that strtok will work */
						if(eq) *eq='=';
						if(q2) *q2='"';
					}
				} else {
					trimnl(t);
					printf("%s", t);
				}

				break;
			}
		}

		/* Read Content-Type if any, and blank line */
		if(NULL==Mgets(buf, sizeof(buf), stdin)){
			if(ERANGE==errno) {
				Error("Maximum input size exceeded."); 
			} else {
				Error("Premature data end after content-disposition.");
			}
		}
		if(0==strncmp(buf, CONTENTTYPE, strlen(CONTENTTYPE))){
			if(match) {
				trimnl(buf+strlen(CONTENTTYPE));
				printf(" contenttype=%s\n", 
					buf+strlen(CONTENTTYPE));
				if(cd) cdparmwrite(cd, f, CONTENTTYPE2, buf+strlen(CONTENTTYPE));
			}
			if(NULL==Mgets(buf, sizeof(buf), stdin)) {
				if(ERANGE==errno) {
					Error("Maximum input size exceeded."); 
				} else {
					Error("Premature data end after content-type.");
				}
			}
		} else if(match) printf("\n");

		/* we should have a blank line now */
		if(0!=strcmp(buf, "\r\n")){
			Error("Unexpected data.");
		}

		/* now comes value -- could be multiple lines. */
		hdr=b=0;
		h=headbuf;
		p=buf;
		while(1){
			int c;
			/*
			 * Compare input stream to headbuf, saving
			 * it as we go.  If we get to the end of
			 * the header and we're still matching, we
			 * have a header. If the match fails before
			 * then, we need to write out the input 
			 * stream and keep going.  p is the pointer
			 * into the input stream, h is the pointer
			 * into the header.
			 */

			/* exit when we've matched the whole header */
			if(hdr>=strlen(headbuf)) break;

			/* sanity check */
			if(p-buf>=sizeof(buf)) Error("Buffer overflow.");

			/* get and save a character */
			if(EOF==(c=Mgetc(stdin))) {
				if(ERANGE==errno) {
					Error("Maximum input size exceeded."); 
				} else Error("Unexpected EOF.");
			}
			*p=(char)c;

			/* primitive progress meter */
			/* if(!(b%1000000)) fprintf(stderr, "."); */
			if(hdr && *p!=*h) {
				/* oops this wasn't a header after all */
				if(match && NULL!=fp) {
					/* write out what we've saved so far */
					if(0==fwrite(buf,sizeof(char),hdr,fp)){
						Error(strerror(errno));
					}
					b+=hdr; /* byte count */
				}
				hdr=0; h=headbuf; buf[0]=*p; p=buf;
			}
			if(*p==*h){
				/* save this character, might be header */
				p++; h++; hdr++;
			} else if(!hdr) {
				if(match && NULL!=fp) {
					if(EOF==fputc(*p,fp)){
						/* write out this character */
						Error(strerror(errno));
					}
				}
				p=buf;
			} 
		}
		if(match && NULL!=fp)(void)fclose(fp);
		match=0;
	}
}

int yywrap(){
	processvalue();
	/* yyterminate(); */
	return(1);
}

%}

BASE 	[0-9a-zA-Z_\[\]]
EXTRA 	[\.\-\*]
HEX	[0-9A-F]


%%

{BASE}+	{ 
	/* characters in use for both names and values */
	t=cat(t, yytext); 
}

{EXTRA}+ { 
	/* characters only in use for values */
	if(parsing==name) {
		parsing=error;
	} else {
		t=cat(t,yytext);
	}
}

"+" { 
	/* spaces are encoded as plus sign */
	t=cat(t, " ");
}

"=" { 
	/* when we hit an = sign, we are at the end of a var name */
	processname();
}

"&" {
	/* when we hit &, we are at the end of a variable value */
	processvalue();
}


"%0D%0A" {
	/* map DOS and Web-style CRLF line endings to UNIX-style newlines */
	if(parsing==name) {
		parsing=error;
	} else {
		t=cat(t, "\n"); 
	}
}

"%"{HEX}{HEX} { 
	/* urlencoded hex values are e.g. %0F for ascii 15 */ 
	if(parsing==name) {
		parsing=error;
	} else {
		char c[2]; 
		c[0]=(char)strtol((char *)(yytext+1), NULL, 16); 
		c[1]='\0'; 
#ifdef notdef
	/* escape single quotes */
		if(c[0]==(char)(39)){ /* single quote */
			t=cat(t, "\\'");
		} else 
#endif /* notdef */
		t=cat(t, (char *)c);
	
	}
}

[% \n]+  /* ignore newlines and % */ {}

. { 
	/* unknown character */
	parsing=error;
}
%%

int main(int argc, char *argv[]){
	int a;
	progname=argv[0];

	opterr=0;
	while(0<=(a=getopt(argc,argv,"VqD:C:M:e:"))){
		switch(a){
		case 'V':
			/* version information */
#ifdef REGEX
			printf("%s REGEX\n",patchlevel);
#else /* !REGEX */
			printf("%s\n",patchlevel);
#endif /* REGEX */
			return(0);
			break;
		case 'C': 
			/* suffix for a subdirectory to hold
			 * content disposition paramaters.  If
			 * variablename is the variable's name
			 * and [suffix] is this suffix, then
			 * a content disposition parameter parmname
			 * will be saved in DIR/variablename[suffix]/parmname
			 * This makes sense only for mime-encoded data.
			 * This option does nothing if directory not specified.
			 */
			cd=optarg;
			break;
		case 'D':
			/* create a new directory (must not already exist)
			 * and put each urlencoded variable as a file in that
			 * directory, the name of which is the variable name, 
			 * and the contents of which are the variable value.
			 */
			dir=optarg;
			if(0!=mkdir(dir, (mode_t)FILEMODE)) Perr(progname);
			break;
		case 'e':
			if(0==strcmp(optarg,URL)){
				ismultipart=NO;
			} else if(0==strcmp(optarg,MULTIPART)){
				ismultipart=YES;
			} else if(0!=strcmp(optarg, AUTODETECT)){
				Error(USAGE);
			}
			break;
		case 'q':
			/* quiet mode.  Close stdout */
			fclose(stdout);
			break;
		case 'M':
			/* maximum size of input. Undocumented for now */
			globalmax=atol(optarg);
			break;
		case '?':
			fprintf(stderr, "%s: Unknown parameter %c\n", 
				progname, optopt);
			Error(USAGE);
			break;
		default:
			break;
		}
	}
	/* figure out encoding if not already specified */
	if(MAYBE==ismultipart){
		/* 
		 * We detect if the input is multipart-encoded
		 * or URL-encoded by seeing if the first character
		 * is '-'. If it is, we assume multipart-encoded,
		 * otherwise URL-encoded.  This isn't perfect,
		 * in theory you can have a URL that loks like this:
		 * "something?-" but in practice it's normally fine.
		 */
		int c;
		if(0>(c=getc(stdin))){
			Error("Can't open stdin.");
		} else if(0>ungetc(c, stdin)){
			Error("Can't ungetc to stdin.");
		}
		if('-'==(char)c) {
			ismultipart=YES; 
		} else {
			ismultipart=NO;
		}
	}
	numvars=argc-optind;  
	vars=&(argv[optind]);	
	if(NULL==(t=malloc(sizeof(char)))||NULL==(f=malloc(sizeof(char))))
		Error("Out of memory.");
	t[0]=f[0]=(char)0;
	if(ismultipart) multipart(); else yylex();
}
