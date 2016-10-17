#LEX=	flex
NAME= cgidecode
DEFINES= -DREGEX
CFLAGS= -g $(DEFINES)
CPP=cpp -P
TBL=tbl
EQN=eqn
HROFF=groff -Thtml

all:	$(NAME) $(NAME).1

$(NAME):	lex.yy.o 
	$(CC) -o $(NAME) lex.yy.o -g $(LIBS)

$(NAME).1:	$(NAME).man
	$(CPP) $(DEFINES) $(NAME).man $(NAME).1 

$(NAME).html:	$(NAME).1
	$(TBL) $(NAME).1 | $(EQN) | $(HROFF) -man >$(NAME).html

lex.yy.c:	$(NAME).lex
	$(LEX) $(NAME).lex

clean:
	$(RM) lex.yy.o lex.yy.c $(NAME) $(NAME).exe $(NAME).1 $(NAME).html

shar:
	shar `awk '{print $$1}' MANIFEST` >$(NAME)-`awk '{print $$7;exit}' patchlevel.h`.shar
