# cgidecode
## Synopsis
**cgidecode** unpacks url-encoded or multipart-encoded data into files.
## Code Example
	cgidecode -e multipart -D mydir -C .cdisp myfile <form-data
	echo Upload filename is: `cat mydir/myfile.cdisp/filename`
	echo Upload filetype is: `cat mydir/myfile.cdisp/content-type`
	echo Upload filesize is: `du -s mydir/myfile`
## Motivation
A shell script makes a good simple CGI language, given a way to convert
url-encoded or multipart-encoded data into a format that is easy for
a shell script to manipulate. **cgidecode** converts url-encoded or
mime-encoded variables into files, where the filename is the name of
the variable and the file content is the value of the variable.
## License
Copyright University of Toronto 2007, 2008, 2010, 2015, 2016.
Written by John DiMarco 

Permission is granted to anyone to use this software for any purpose on
any computer system, and to alter it and redistribute it freely, subject
to the following restrictions:
1. The author and the University of Toronto are not responsible 
   for the consequences of use of this software, no matter how awful, 
   even if they arise from flaws in it.
2. The origin of this software must not be misrepresented, either by
   explicit claim or by omission.  Since few users ever read sources,
   credits must appear in the documentation.
3. Altered versions must be plainly marked as such, and must not be
   misrepresented as being the original software.  Since few users
   ever read sources, credits must appear in the documentation.
4. This notice may not be removed or altered.
