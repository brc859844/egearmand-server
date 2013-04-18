-module(rabbit_backend) .

%% @doc
%% Functions for manipulating a rabbitmq system
%% used in the rabbitmq extension.

-author("Antonio Garrote Hernandez") .

-behaviour(gen_server) .

-include_lib("states.hrl").
-include_lib("rabbit_states.hrl").
-include("amqp_client/include/amqp_client.hrl").

-export([start/0, start_link/0, create_queue/1, publish/3, consume/2]) .
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([code_change/3]).


%% public API


%% @doc
%% Starts the rabbitmq application
start() ->
    application:start(sasl) ,
    application:start(mnesia) ,
    application:start(os_mon) ,
    application:start(rabbit) .


%% @doc
%% Starts the backend
start_link() ->
    gen_server:start_link({local, rabbit_backend}, rabbit_backend, [], []) .


%% Creates a new queu with Options.
create_queue(Options) ->
    gen_server:call(rabbit_backend, {create, Options}) .


%% Publishes Content to the Queue using RoutingKey.
publish(Content, Queue, RoutingKey) ->
    gen_server:call(rabbit_backend, {publish, Content, Queue, RoutingKey}) .


%% creates a new process consuming messages from the Queue.
consume(F,Queue) ->
    gen_server:call(rabbit_backend, {consume, F, Queue}) .


%% callbacks


init(_Arguments) ->
    Params = #amqp_params_network{ username = configuration:rabbit_user(),
			           password = configuration:rabbit_password() },
    {ok, Connection} = amqp_connection:start(Params),
    {ok, Channel} = amqp_connection:open_channel(Connection),

    %% Note that ticket is not used; just set it to "Channel" to keep things happy
    %%
    {ok, #rabbit_queue_state{ connection = Connection, channel = Channel, ticket = Channel } } .


code_change(_OldVsn, State, _Extra) ->
    %% No change planned. The function is there for the behaviour,
    %% but will not be used.
    {ok, State}.


handle_call({create, Options}, _From, State) ->
    log:debug(["rabbit_backend handle_call create",Options]),
    AlreadyDeclared = proplists:is_defined(proplists:get_value(name,Options),State#rabbit_queue_state.queues),
    if AlreadyDeclared =:= false ->
            try declare_queue(Options, State) of
                Queue     -> { reply, ok, State#rabbit_queue_state{ queues = [ Queue | State#rabbit_queue_state.queues ] } }
            catch
                _Exception -> { reply, error, State }
            end ;
       true -> {reply, ok, State}
    end ;

handle_call({publish, Content, Queue, BindingKey}, _From, State) ->
    AlreadyDeclared = proplists:is_defined(Queue,State#rabbit_queue_state.queues),
    if AlreadyDeclared =:= false ->
            try declare_queue([{queue, Queue, {bindkey, Queue}}], State) of
                Queue     -> publish_content(Content, Queue, BindingKey, State),
                             { reply, ok, State#rabbit_queue_state{ queues = [ Queue | State#rabbit_queue_state.queues ] } }
            catch
                _Exception -> { reply, error, State }
            end ;
       true -> publish_content(Content, Queue, BindingKey, State),
               {reply, ok, State}
    end ;

handle_call({consume, Function, Queue}, _From, State) ->
    AlreadyDeclared = proplists:is_defined(Queue,State#rabbit_queue_state.queues),

    if AlreadyDeclared =:= false ->
            try declare_queue([{queue, Queue}, {bindkey, Queue}], State) of
                Queue     -> register_consumer(Function, Queue, State),
                             { reply, ok, State#rabbit_queue_state{ queues = [ Queue | State#rabbit_queue_state.queues ] } }
            catch
                _Exception -> { reply, error, State }
            end ;
       true -> register_consumer(Function, Queue, State),
               {reply, ok, State}
    end .

%% dummy callbacks so no warning are shown at compile time
handle_cast(_Msg, State) ->
    {noreply, State} .

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(shutdown, #connections_state{ socket = _ServerSock }) ->
    ok.


%% private API


%% @doc
%% Default values for channel configuration
%% options of RabbitMQ
channel_default_values() ->
    [ {realm, <<"gearman">>},
      {exclusive, false},
      {passive, false},
      {active, true},
      {write, true},
      {read, true} ] .

%% @doc
%% Default values for exchange configuration
%% options of RabbitMQ
exchange_default_values() ->
    [ {type, <<"direct">>},
      {passive, false},
      {durable, false},
      {auto_delete, false},
      {internal, false},
      {nowait, false},
      {arguments, []} ] .


%% @doc
%% sets up a new channel over an already stablished connection
%% using the configuration values and the default ones
channel_setup(Connection) ->
    Configuration = configuration:rabbit_channel_configuration(),
    Defaults = channel_default_values(),
    Access = #'access.request'{ realm = proplists_extensions:get_value(realm,  Configuration, Defaults),
                                exclusive = proplists_extensions:get_value(exclusive,  Configuration, Defaults),
                                passive = proplists_extensions:get_value(passive,  Configuration, Defaults),
                                active = proplists_extensions:get_value(active,  Configuration, Defaults),
                                write = proplists_extensions:get_value(write,  Configuration, Defaults),
                                read = proplists_extensions:get_value(read,  Configuration, Defaults) },
    Channel = amqp_connection:open_channel(Connection),
    #'access.request_ok'{ticket = Ticket} = amqp_channel:call(Channel, Access),
    {Channel, Ticket} .



%% @doc
%% Creates a new queue
declare_queue(Options, State) ->
    Q = proplists:get_value(name, Options),
    X = <<"x">>,
    BindKey = proplists:get_value(routing_key, Options),

    QueueDeclare = #'queue.declare'{queue = Q,
                                    passive = false,
                                    durable = false,
                                    exclusive = false,
                                    auto_delete = false,
                                    nowait = false,
                                    arguments = []},
    #'queue.declare_ok'{} = amqp_channel:call(State#rabbit_queue_state.channel, QueueDeclare),

    ExchangeDeclare = #'exchange.declare'{exchange = X,
					  ticket = 0,
                                          type= <<"direct">>,
                                          passive = false,
                                          durable = false,
                                          auto_delete=false,
                                          internal = false,
                                          nowait = false,
                                          arguments = []},
    #'exchange.declare_ok'{} = amqp_channel:call(State#rabbit_queue_state.channel, ExchangeDeclare),

    QueueBind = #'queue.bind'{queue = Q,
                              exchange = X,
                              routing_key = BindKey},

    #'queue.bind_ok'{} = amqp_channel:call(State#rabbit_queue_state.channel, QueueBind),
    {Q, #rabbit_queue{ queue = Q, exchange = X, key = BindKey }} .


publish_content(Content, Queue, BindingKey, State) ->
    QueueState = proplists:get_value(Queue, State#rabbit_queue_state.queues),
    log:debug(["rabbit_backend publish_content :",
               {queue, Queue},
               {ticket, State#rabbit_queue_state.ticket},
               {exchange, QueueState#rabbit_queue.exchange},
               {routing_key, BindingKey}]),
    BasicPublish = #'basic.publish'{exchange = QueueState#rabbit_queue.exchange,
                                    routing_key = BindingKey},
    Payload = #amqp_msg{payload = list_to_binary([Content])},
    amqp_channel:cast(State#rabbit_queue_state.channel, BasicPublish, Payload) .


register_consumer(Function, Queue, State) ->
    BasicConsume = #'basic.consume'{queue = Queue,
                                    consumer_tag = <<"">>,
                                    no_local = false,
                                    no_ack = true,
                                    exclusive = false,
                                    nowait = false},

    ConsumerPid = spawn_consumer(Function, State#rabbit_queue_state.channel),

    #'basic.consume_ok'{consumer_tag = _Tag} = amqp_channel:subscribe(State#rabbit_queue_state.channel, BasicConsume, ConsumerPid),

    ConsumerPid .


spawn_consumer(Function, Channel) ->
    spawn(fun() ->
                  %% If the registration was sucessful, the consumer will
                  %% be notified
                  receive
                      #'basic.consume_ok'{consumer_tag = ConsumerTag} -> ok
                  end,
                  ConsumeLoop = fun(F) ->

                                        receive
                                            {#'basic.deliver'{delivery_tag = _DeliveryTag}, Content} ->

                                                #amqp_msg{payload = DeliveredPayload} = Content,
                                                %% TODO pass the value read to the Function passed as a parameter
                                                Function([DeliveredPayload]),
                                                F(F);

                                            exit ->

                                                %% After the consumer is finished interacting with the
                                                %% queue, it can deregister itself

                                                BasicCancel = #'basic.cancel'{consumer_tag = ConsumerTag,
                                                                              nowait = false},
                                                #'basic.cancel_ok'{consumer_tag = ConsumerTag}
                                                    = amqp_channel:call(Channel,BasicCancel)
                                        end
                                end,
                  ConsumeLoop(ConsumeLoop)
          end) .


%% tests


direct_queue_test() ->
    %% first get the connection
    Params = #amqp_params_network{ username = <<"zaphod">>,
                                   password = <<"zaphod">> },
    {ok, ConnectionPid} = amqp_connection:start(Params),

    %% Get a channel
    {ok, Channel} = amqp_connection:open_channel(ConnectionPid),


    %% Declare a queue, exchange and binding
    Q = <<"test">>,
    X = <<"x">>,
    BindKey = <<"test_key">>,

    QueueDeclare = #'queue.declare'{queue = Q,
                                    passive = false,
                                    durable = false,
                                    exclusive = false,
                                    auto_delete = false,
                                    nowait = false,
                                    arguments = []},
    #'queue.declare_ok'{} = amqp_channel:call(Channel, QueueDeclare),


    ExchangeDeclare = #'exchange.declare'{exchange = X,
					  ticket = 0,
                                          type= <<"direct">>,
                                          passive = false,
                                          durable = false,
                                          auto_delete=false,
                                          internal = false,
                                          nowait = false,
                                          arguments = []},
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchangeDeclare),


    QueueBind = #'queue.bind'{queue = Q,
                              exchange = X,
                              routing_key = BindKey},
    #'queue.bind_ok'{} = amqp_channel:call(Channel, QueueBind),

    %% Register a consumer
    BasicConsume = #'basic.consume'{queue = Q,
                                    consumer_tag = <<"">>,
                                    no_local = false,
                                    no_ack = true,
                                    exclusive = false,
                                    nowait = false},

    ConsumerPid = spawn(fun() ->
                                %% If the registration was sucessful, the consumer will
                                %% be notified
                                receive
                                    #'basic.consume_ok'{consumer_tag = _ConsumerTag} -> ok
                                end,

                                ConsumeLoop = fun(F) ->
                                        %% When a message is routed to the queue, it will be
                                        %% delivered to this consumer
                                       receive
                                            {#'basic.deliver'{delivery_tag = _DeliveryTag}, Content} ->
                                                #amqp_msg{payload = Payload} = Content,
                                                %% TODO pass the value read to the Function passed as a parameter
                                                io:format("Message received: ~p~n", [Payload]),
                                                F(F)
                                        end
                                end,
                                ConsumeLoop(ConsumeLoop)
                        end),

    amqp_channel:subscribe(Channel, BasicConsume, ConsumerPid),

    %% Let's publish something
    log:t(["Publishing to:",
           {queue, Q},
           {exchange, X},
           {routing_key, BindKey}]),

    BasicPublish = #'basic.publish'{exchange = X,
                                    routing_key = BindKey},
    Payload = #amqp_msg{payload = list_to_binary(["hola"])},
    amqp_channel:cast(Channel, BasicPublish, Payload) .

