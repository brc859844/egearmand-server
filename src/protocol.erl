-module(protocol) .

-author("Antonio Garrote Hernandez") .

-include_lib("eunit/include/eunit.hrl").

%-export([parse_command/2, process_request/2, parse_command/1]) .
-compile(export_all).

%% @doc
%% @author 'Samuel Stauffer <samuel@lefora.com>'
%% @see git://github.com/samuel/erlang-gearman.git
-spec(parse_command/1 :: (Data :: binary()) -> {'error', 'not_enough_data'} | {'ok', binary(), atom(), atom()} | {'ok', binary(), atom(), tuple()}).
parse_command(Data) when size(Data) >= 12 ->
    <<"\000RE", TypeChar:8, CommandID:32/big, DataLength:32/big, Rest/binary>> = Data,
    if
        size(Rest) >= DataLength ->
            Type = case TypeChar of
                $Q -> request;
                $S -> response
            end,
            {ArgData, LeftOverData} = split_binary(Rest, DataLength),
            Command = parse_command(CommandID, binary_to_list(ArgData)),
            {ok, LeftOverData, Type, Command};
        true ->
            {error, not_enough_data}
    end;
parse_command(_Data) ->
    {error, not_enough_data}.

parse_command(CommandID, Data) ->
    case CommandID of
        22 -> {set_client_id, Data}; % ClientID
        16 -> {echo_req, Data}; % Text
        12 ->
            [Handle, Numerator, Denominator] = split(Data, 0, 2),
            {work_status, Handle, list_to_integer(Numerator), list_to_integer(Denominator)};
        13 ->
            [Handle, Result] = split(Data, 0, 1),
            {work_complete, Handle, Result};
        14 -> {work_fail, Data}; % Handle
        17 -> {echo_res, Data}; % Text
        19 ->
            [Code, Text] = split(Data, 0, 1),
            {error, list_to_integer(Code), Text};
        1 -> {can_do, Data}; % Function
        23 ->
            [Function, Timeout] = split(Data, 0, 1),
            {can_do_timeout, Function, list_to_integer(Timeout)};
        2 -> {cant_do, Data}; % Function
        3 -> reset_abilities;
        4 -> pre_sleep;
        9 -> grab_job;
        11 ->
            [Handle, Function, Argument] = split(Data, 0, 2),
            {job_assign, Handle, Function, Argument};
        24 -> all_yours;
        6 -> noop;
        10 -> no_job;
        7 ->
            [Function, Unique, Argument] = split(Data, 0, 2),
            {submit_job, Function, Unique, Argument};
        21 ->
            [Function, Unique, Argument] = split(Data, 0, 2),
            {submit_job_high, Function, Unique, Argument};
        33 ->
            [Function, Unique, Argument] = split(Data, 0, 2),
            {submit_job_low, Function, Unique, Argument};
        18 ->
            [Function, Unique, Argument] = split(Data, 0, 2),
            {submit_job_bg, Function, Unique, Argument};
        8 -> {job_created, Data}; % Handle
        15 -> {get_status, Data}; % Handle
        20 ->
            [Handle, Known, Running, Numerator, Denominator] = split(Data, 0, 4),
            {status_res, Handle, Known, Running, list_to_integer(Numerator), list_to_integer(Denominator)}
    end.

pack_request(Command, Args) when is_atom(Command), is_tuple(Args) ->
    {CommandID, ArgList} = pack_command(Command, Args),
    pack_command(CommandID, ArgList, "\000REQ").
pack_response(Command, Args) when is_atom(Command), is_tuple(Args) ->
    {CommandID, ArgList} = pack_command(Command, Args),
    pack_command(CommandID, ArgList, "\000RES").
pack_command(CommandID, Args, Magic) when is_integer(CommandID), is_list(Args), is_list(Magic) ->
    Data = list_to_binary(join(Args, [0])),
    DataLength = size(Data),
    list_to_binary([Magic, <<CommandID:32/big, DataLength:32/big>>, Data]).

pack_command(set_client_id, {ClientID}) -> {22, [ClientID]};
pack_command(echo_req, {Text}) -> {16, [Text]};
pack_command(work_status, {Handle, Numerator, Denominator}) -> {12, [Handle, integer_to_list(Numerator), integer_to_list(Denominator)]};
pack_command(work_complete, {Handle, Result}) -> {13, [Handle, Result]};
pack_command(work_fail, {Handle}) -> {14, [Handle]};
pack_command(echo_res, {Text}) -> {17, [Text]};
pack_command(error, {Code, Text}) -> {19, [integer_to_list(Code), Text]};
pack_command(can_do, {Func}) -> {1, [Func]};
pack_command(can_do_timeout, {Func, Timeout}) -> {23, [Func, integer_to_list(Timeout)]};
pack_command(cant_do, {Func}) -> {2, [Func]};
pack_command(reset_abilities, {}) -> {3, []};
pack_command(pre_sleep, {}) -> {4, []};
pack_command(grab_job, {}) -> {9, []};
pack_command(job_assign, {Handle, Func, Arg}) -> {11, [Handle, Func, Arg]};
pack_command(all_yours, {}) -> {24, []};
pack_command(noop, {}) -> {6, []};
pack_command(no_job, {}) -> {10, []};
pack_command(submit_job, {Func, Uniq, Arg}) -> {7, [Func, Uniq, Arg]};
pack_command(submit_job_high, {Func, Uniq, Arg}) -> {21, [Func, Uniq, Arg]};
pack_command(submit_job_low, {Func, Uniq, Arg}) -> {33, [Func, Uniq, Arg]};
pack_command(submit_job_bg, {Func, Uniq, Arg}) -> {18, [Func, Uniq, Arg]};
pack_command(job_created, {Handle}) -> {8, [Handle]};
pack_command(get_status, {Handle}) -> {15, [Handle]};
pack_command(status_res, {Handle, Known, Running, Numerator, Denominator}) -> {20, [Handle, Known, Running, integer_to_list(Numerator), integer_to_list(Denominator)]}.


%% Join a list of lists into a single list separated by Separator
join([], _) -> [];
join([Head|Lists], Separator) ->
     lists:flatten([Head | [[Separator, Next] || Next <- Lists]]).


%% Split a list into multiple lists by Separator
split(List, Separator, Count) ->
    split(List, Separator, [], [], Count).

split([], _, [], [], _) -> [];  %% empty set
split([], _, Lists, Current, _) -> Lists ++ [Current]; %% nothing left to split
split(List, _, Lists, [], 0) -> Lists ++ [List];
split([Separator|Rest], Separator, Lists, Current, Count) when Count > 0 ->
    split(Rest, Separator, Lists ++ [Current], [], Count-1);
split([Other|Rest], Separator, Lists, Current, Count) when Count > 0 ->
    split(Rest, Separator, Lists, Current ++ [Other], Count).

%% handling the logic
process_request(Bin, Msgs) ->
    log:t(["Processing request", protocol:parse_command(Bin)]),
    case protocol:parse_command(Bin) of
        {ok,<<>>, _Kind, {Cmd,Arg1, Arg2}} ->
            lists:reverse([{Cmd,[Arg1, Arg2]} | Msgs]) ;

        {ok,LeftOver, _Kind, {Cmd,Arg1, Arg2}} ->
            process_request(LeftOver, [{Cmd,[Arg1, Arg2]} | Msgs]) ;

        {ok,<<>>, _Kind, {Cmd,Arg1, Arg2, Arg3}} ->
            lists:reverse([{Cmd,[Arg1, Arg2, Arg3]} | Msgs]) ;

        {ok,LeftOver, _Kind, {Cmd,Arg1, Arg2, Arg3}} ->
            process_request(LeftOver, [{Cmd,[Arg1, Arg2, Arg3]} | Msgs]) ;

        {ok,<<>>, _Kind, {Cmd,Args}} ->
            lists:reverse([{Cmd,Args} | Msgs]) ;

        {ok, LeftOver, _Kind, {Cmd,Args}} ->
            process_request(LeftOver, [{Cmd,Args} | Msgs]) ;

        {ok,<<>>, _Kind, Cmd} ->
            lists:reverse([{Cmd, none} | Msgs]) ;

        {ok, LeftOver, _Kind, Cmd} ->
            process_request(LeftOver, [{Cmd, none} | Msgs]) ;

        Error ->
            {error, Error}
    end .


%% tests
process_request_test() ->
    Cmd = <<0,82,69,81,0,0,0,22,0,0,0,0,0,82,69,81,0,0,0,1,0,0,0,19,100,105,
              114,101,99,116,111,114,121,95,112,105,110,103,95,97,108,102,97,
              0,82,69,81,0,0,0,1,0,0,0,19,100,105,114,101,99,116,111,114,121,
              95,101,120,105,116,95,97,108,102,97,0,82,69,81,0,0,0,1,0,0,0,26,
              100,105,114,101,99,116,111,114,121,95,103,101,110,101,114,97,
              116,111,114,95,119,111,114,107,101,114,0,82,69,81,0,0,0,9,0,0,0,
              0>>,
    Result = process_request(Cmd,[]),
    ?assertEqual(5, length(Result)) .
