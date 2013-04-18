INC = -I$(HOME) -I. -I..

OPT = -Wall -pa $(HOME)/rabbitmq-server/ebin

BEAMS = rabbitmq_extension.beam rabbit_backend.beam


.SUFFIXES:      .erl .beam

.erl.beam:
		erlc $(OPT) $(INC) $<

all:            $(BEAMS) move

move:           $(BEAMS)
		mv $(BEAMS) ../../ebin/

clean:
		rm -rf *.beam

