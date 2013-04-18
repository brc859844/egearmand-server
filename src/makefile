INC = -I$(HOME)

OPT = -Wall -pa $(HOME)/rabbitmq-server/ebin

APP = egearmand.app

BEAMS = administration.beam \
client_proxy.beam \
configuration.beam \
connections.beam \
egearmand_app.beam \
functions_registry.beam \
gearmand_slave_supervisor.beam \
gearmand_supervisor.beam \
jobs_queue_server.beam \
lists_extensions.beam \
log.beam \
mnesia_store.beam \
proplists_extensions.beam \
protocol.beam \
store.beam \
tests.beam \
worker_proxy.beam \
workers_registry.beam


.SUFFIXES:      .erl .beam

.erl.beam:
		erlc $(OPT) $(INC) $<

all:            $(BEAMS) app move rabbit

rabbit:
		(cd extensions; make)

app:            $(APP)
		cp $(APP) ../ebin/

move:           $(BEAMS)
		mv $(BEAMS) ../ebin/

clean:
		rm -rf *.beam
		(cd extensions; make clean)


