%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(rs_fsm).

-behaviour(gen_fsm).
-compile(export_all).                           % XXX debugging only

%% API
-export([write/7, write/10]).
-export([get_local_riak_client/0, free_local_riak_client/1]).

%% gen_fsm callbacks
-export([init/1, prepare_write/2, prepare_write/3, handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).
-export([t_write/0, t_write_test/0,
         t_read/0, t_read_test/0]).

-define(ALG_FAKE_V0,       'alg_fake0').
-define(ALG_LIBER8TION_V0, 'alg_liber8tion0').

-type ec_algorithm() ::'fake0' | 'liber8tion0'.

-record(state, {
          caller :: pid(),
          mode :: 'read' | 'write',
          alg :: ec_algorithm(),
          k :: pos_integer(),
          m :: pos_integer(),
          rbucket :: binary(),
          rsuffix :: binary(),
          data :: binary(),
          tref :: undefined | reference(),
          get_client_fun :: fun(),
          free_client_fun :: fun(),
          robj_mod :: atom(),
          riak_client :: undefined | term(),
          xx :: term()
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Start a new write op using Reed-Solomon erasure coding
%%
%% We will use a Reed-Solomon-style algorithm Alg, factors K & M,
%% using Riak bucket RBucket and RSuffix for the Riak key suffix.
%%
%% K = number of data pieces
%% M = number of parity pieces
%%
%% The Alg atom will encode some algorithm assumptions that the rest
%% of this code will also assume, e.g.
%%   * ?ALG_LIBER8TION_V0 will use w=8 *and* it will assume a very
%%     particular version of the NIF-to-be's implementation of
%%     the liber8tion algorithm.  For example, if the NIF can't
%%     provide that exact version, then we must fail.  Paranoia!
%%
%% @spec start() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
write(Alg, K, M, RBucket, RSuffix, Data, Timeout) ->
    write(Alg, K, M, RBucket, RSuffix, Data, Timeout,
          fun get_local_riak_client/0, fun free_local_riak_client/1,
          riak_object).

write(Alg, K, M, RBucket, RSuffix, Data, Timeout,
      GetClientFun, FreeClientFun, RObjMod) ->
    {ok, Pid} = start_write(Alg, K, M, RBucket, RSuffix, Data, Timeout,
                            GetClientFun, FreeClientFun, RObjMod),
    wait_for_reply(Pid, Timeout).

start_write(Alg, K, M, RBucket, RSuffix, Data, Timeout,
            GetClientFun, FreeClientFun, RObjMod) ->
    Alg = ?ALG_FAKE_V0,

    gen_fsm:start(
      ?MODULE, {write, Alg, K, M, RBucket, RSuffix, Data, Timeout, self(),
                GetClientFun, FreeClientFun, RObjMod}, []).

read(Alg, K, M, RBucket, RSuffix, Timeout) ->
    read(Alg, K, M, RBucket, RSuffix, Timeout,
         fun get_local_riak_client/0, fun free_local_riak_client/1,
         riak_object).

read(Alg, K, M, RBucket, RSuffix, Timeout,
      GetClientFun, FreeClientFun, RObjMod) ->
    {ok, Pid} = start_read(Alg, K, M, RBucket, RSuffix, Timeout,
                           GetClientFun, FreeClientFun, RObjMod),
    wait_for_reply(Pid, Timeout).

start_read(Alg, K, M, RBucket, RSuffix, Timeout,
           GetClientFun, FreeClientFun, RObjMod) ->
    Alg = ?ALG_FAKE_V0,

    gen_fsm:start(
      ?MODULE, {read, Alg, K, M, RBucket, RSuffix, Timeout, self(),
                GetClientFun, FreeClientFun, RObjMod}, []).

get_local_riak_client() ->
    riak:local_client().

free_local_riak_client(_) ->
    ok.

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init({write, Alg, K, M, RBucket, RSuffix, Data, Timeout, Caller,
      GetClientFun, FreeClientFun, RObjMod})
    when is_integer(K) andalso K > 0 andalso
         is_integer(M) andalso M > 0 andalso
         is_binary(RBucket) andalso is_binary(RSuffix) andalso
         is_binary(Data) ->
    TRef = if Timeout == infinity ->
                   undefined;
              true ->
                   erlang:send_after(Timeout, self(), final_timeout)
           end,
    {ok, prepare_write, #state{caller = Caller,
                               mode = write,
                               alg = Alg,
                               k = K,
                               m = M,
                               rbucket = RBucket,
                               rsuffix = RSuffix,
                               data = Data,
                               tref = TRef,
                               get_client_fun = GetClientFun,
                               free_client_fun = FreeClientFun,
                               robj_mod = RObjMod}, 0};
init({read, Alg, K, M, RBucket, RSuffix, Timeout, Caller,
      GetClientFun, FreeClientFun, RObjMod})
    when is_integer(K) andalso K > 0 andalso
         is_integer(M) andalso M > 0 andalso
         is_binary(RBucket) andalso is_binary(RSuffix) ->
    TRef = if Timeout == infinity ->
                   undefined;
              true ->
                   erlang:send_after(Timeout, self(), final_timeout)
           end,
    {ok, prepare_read, #state{caller = Caller,
                              mode = write,
                              alg = Alg,
                              k = K,
                              m = M,
                              rbucket = RBucket,
                              rsuffix = RSuffix,
                              tref = TRef,
                              get_client_fun = GetClientFun,
                              free_client_fun = FreeClientFun,
                              robj_mod = RObjMod}, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec prepare_write(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
prepare_write(timeout, S) ->
    {ok, Client} = (S#state.get_client_fun)(),
    %% XXX
    %% {Bucket, Keys, Frags} = ec_encode(S#state.data, S),
    %% RObj = (S#state.robj_mod):new(Bucket, Key, S#state.data),
    %% XX = Client:put(RObj),
    XX = xxx,
    {next_state, write_waiting_replies, S#state{riak_client = Client,
                                                xx = XX}, 0}.

write_waiting_replies(timeout, S) ->
    send_reply(S#state.caller, S#state.xx),
    {stop, normal, S}.

prepare_read(timeout, S) ->
    {ok, Client} = (S#state.get_client_fun)(),
    {Bucket, Key} = {xxx, xxx},
    %% XXX {Bucket, Key} = encode_bkey(S),
    XX = Client:get(Bucket, Key),
    {next_state, read_waiting_replies, S#state{riak_client = Client,
                                               xx = XX}, 0}.

read_waiting_replies(timeout, S) ->
    send_reply(S#state.caller, S#state.xx),
    {stop, normal, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/[2,3], the instance of this function with
%% the same name as the current state name StateName is called to
%% handle the event.
%%
%% @spec prepare_write(Event, From, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
prepare_write(_Event, _From, State) ->
    Reply = neverNEVAHHH,
    {reply, Reply, prepare_write, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, S) ->
    erlang:cancel_timer(S#state.tref),
    (S#state.free_client_fun)(S#state.riak_client),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% --- Riak bucket & key encoding/decoding

encode_key(Frag, #state{alg = Alg, k = K, m = M, rsuffix = Suffix}) ->
    encode_key(Alg, K, M, Frag, Suffix).

encode_key(Alg, K, M, Frag, Suffix) ->
    Code = alg_to_code(Alg),
    <<"st", Code:8, K:8, M:8, Frag:8, Suffix/binary>>.

decode_key(<<"st", Code:8, K:8, M:8, Frag:8, Suffix/binary>>) ->
    {code_to_alg(Code), K, M, Frag, Suffix}.

alg_to_code(?ALG_FAKE_V0)       -> $f;
alg_to_code(?ALG_LIBER8TION_V0) -> $l.

code_to_alg($f) -> ?ALG_FAKE_V0;
code_to_alg($l) -> ?ALG_LIBER8TION_V0.

%% --- Fake erasure encoding/decoding

ec_encode(Bin, #state{alg = Alg, k = K, m = M,
                      rbucket = Bucket, rsuffix = Suffix}) ->
    ec_encode(Bin, Alg, K, M, Bucket, Suffix).

ec_encode(<<>>, _, _, _, _, _) ->
    [];
ec_encode(Bin, Alg, K, M, Bucket, Suffix) ->
    NumFrags = K + M,
    Buckets = lists:duplicate(NumFrags, Bucket),
    Keys = ec_encode_keys(Alg, K, M, Suffix, lists:seq(0, NumFrags - 1)),
    Frags = ec_encode_data(Bin, Alg, K, M),
    lists:zip3(Buckets, Keys, Frags).

ec_encode_keys(Alg, K, M, Suffix, Frags) ->
    [encode_key(Alg, K, M, Frag, Suffix) || Frag <- Frags].

ec_encode_data(Bin, ?ALG_FAKE_V0, K, M) ->
    BinSize = size(Bin),
    BinSizeRemK = BinSize rem K,
    if K == 1 ->
            FragSize = BinSize,
            PadSize = 0;
       BinSizeRemK == 0 ->
            FragSize = BinSize div K,
            PadSize = 0;
       true ->
            FragSize = (BinSize div K) + 1,
            PadSize = K - BinSizeRemK
    end,
    ec_fake_split_bin(FragSize, Bin, K, PadSize) ++
        [<<(X+42):(FragSize * 8)>> || X <- lists:seq(0, M - 1)].

ec_fake_split_bin(1, Bin, K, PadSize) when size(Bin) < K ->
    ec_fake_split_small(Bin) ++ lists:duplicate(PadSize, <<0>>);
ec_fake_split_bin(FragSize, Bin, _K, Padsize) ->
    ec_fake_split_bin_big(FragSize, Bin, Padsize).

ec_fake_split_small(<<>>) ->
    [];
ec_fake_split_small(<<Head:1/binary, Rest/binary>>) ->
    [Head|ec_fake_split_small(Rest)].

ec_fake_split_bin_big(FragSize, Bin, PadBytes)
  when size(Bin) >= FragSize ->
    <<Head:FragSize/binary, Rest/binary>> = Bin,
    [Head|ec_fake_split_bin_big(FragSize, Rest, PadBytes)];
ec_fake_split_bin_big(_, <<>>, 0) ->
    [];
ec_fake_split_bin_big(FragSize, Last, PadBytes) when FragSize < PadBytes ->
    Pad1Size = FragSize - size(Last),
    NumPad2s = PadBytes div FragSize,
    Pad2s = lists:duplicate(NumPad2s, <<0:(8*FragSize)>>),
    if Last == <<>> ->
            Pad2s;
       true ->
            [<<Last/binary, 0:(8*Pad1Size)>>|Pad2s]
    end;
ec_fake_split_bin_big(_FragSize, Last, PadBytes) ->
    [<<Last/binary, 0:(8*PadBytes)>>].

%% --- Misc

zip_1xx(_A, [], []) ->
    [];
zip_1xx(A, [B|Bx], [C|Cx]) ->
    [{A, B, C}|zip_1xx(A, Bx, Cx)].

monitor_pid(Pid) ->
    erlang:monitor(process, Pid).

demonitor_pid(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref),
    receive
        {'DOWN', Ref, _, _, _} ->
            true
    after 0 ->
            true
    end.

send_reply(Pid, Reply) ->
    Pid ! {?MODULE, reply, Reply}.

%% Note that we assume that the pid we're waiting for is going to
%% do the right thing wrt timeouts.

wait_for_reply(Pid, Timeout0) ->
    Timeout = if Timeout0 == infinity -> infinity;
                 true                 -> Timeout0 + 200
              end,
    WRef = monitor_pid(Pid),
    try
        receive
            {?MODULE, reply, Reply} ->
                Reply;
            {'DOWN', WRef, _, _, Info} ->
                {error, Info}
        after
            Timeout ->
                timeout
        end
    after
        demonitor_pid(WRef)
    end.

t_write() ->
    write(?ALG_FAKE_V0, 3, 2, <<"rb">>, <<"rs">>, <<"data">>, 500).

t_write_test() ->
    ok = t_write().

t_read() ->
    read(?ALG_FAKE_V0, 3, 2, <<"rb">>, <<"rs">>, 500).

t_read_test() ->
    ok = t_read().

t_fake_encode_test() ->
    Bins = [list_to_binary(lists:seq(1, X)) || X <- lists:seq(1, 40)],
    Ks = lists:seq(1, 13),
    Ms = lists:seq(0, 13),
    Bucket = <<"bucket">>,
    Suffix = <<"suffix">>,
    [begin
         %% io:format("size(Bin) ~p K ~p M ~p\n", [size(Bin), K, M]),
         Es = ec_encode(Bin, ?ALG_FAKE_V0, K, M, Bucket, Suffix),
         %% We won't check the parity frags, since they're all bogus.
         %% Instead, compare the original Bin + plus any addtional padding
         %% to the concatenation of all of the K data frags.
         %% and then compare to the K data
         %% frags.
         BinSize = size(Bin),
         PadBytes = if K == 1 ->
                           0;
                      size(Bin) rem K == 0 ->
                           0;
                      true ->
                           K - (size(Bin) rem K)
                   end,
         %% PadBytes = if K == size(Bin) ->
         %%                   0;
         %%              %% size(Bin) < K ->
         %%              %%      K - size(Bin);
         %%              size(Bin) rem K == 0 ->
         %%                   0;
         %%              true ->
         %%                   K - (size(Bin) rem K)
         %%           end,
         Pad = list_to_binary([0 || _ <- lists:seq(0, PadBytes-1)]),
         CatKFrags = list_to_binary([Frag || {_, _, Frag} <-
                                                 lists:sublist(Es, K)]),
         {Bin, K, M, Pad, <<Bin:BinSize/binary, Pad/binary>>} =
             {Bin, K, M, Pad, CatKFrags}
     end || Bin <- Bins, K <- Ks, M <- Ms],
    ok.