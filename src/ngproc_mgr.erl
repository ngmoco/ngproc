%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc 
%% @end
%%%-------------------------------------------------------------------
-module(ngproc_mgr).

-behaviour(gen_leader).

-include("ng_log.hrl").
-include("ngproc.hrl").
-include_lib("gen_leader/include/gen_leader_specs.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/0
         ,register/3
         ,reregister/2
         ,unregister/1
        ]).

%% gen_leader callbacks
-export([init/1,
         elected/3,
         surrendered/3,
         handle_leader_call/4,
         handle_leader_cast/3,
         from_leader/3,
         handle_call/4,
         handle_cast/3,
         handle_DOWN/3,
         handle_info/2,
         terminate/2,
         code_change/4
        ]).

-record(state, {tid}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec start_link() -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
%% @end
%%--------------------------------------------------------------------
start_link() ->
    CandNodes = ngproc_app:config(cluster_nodes),
    gen_leader:start_link(?MODULE, CandNodes, [], ?MODULE, [], []).

register(Name, Pid, Resolver) ->
    %% Local check for existing registration - bail out early?
    gen_leader:leader_call(?MODULE, {register, Name, Pid, Resolver}).

reregister(Name, NewPid) ->
    gen_leader:leader_call(?MODULE, {reregister, Name, NewPid}).

unregister(Name) ->
    gen_leader:leader_call(?MODULE, {unregister, Name}).

%%====================================================================
%% gen_leader callbacks
%%====================================================================

init([]) ->
    Tid = ets:new(?NGPROC_NAMES, [named_table, protected, ordered_set]),
    {ok, #state{tid=Tid}}.
 
elected(S = #state{}, _E, _Node) ->
    erlang:error(not_implemented),
    {reply, all_names, S}.

surrendered(S = #state{}, _Sync, _E) ->
    {ok, S}.

handle_leader_call({register, Name, Pid, Resolver}, _From, S = #state{}, _E) ->
    case ngproc_lib:register(Name, Pid, Resolver) of
        registered ->
            {reply, ok, {register, Name, Pid, Resolver}, S};
        {duplicate, Pid} ->
            {reply, {duplicate, Pid}, S}
    end;
handle_leader_call({reregister, Name, NewPid}, _From, S, _E) ->
    case ngproc_lib:reregister(Name, NewPid) of
        reregistered ->
            {reply, ok, {reregister, Name, NewPid}, S};
        not_registered ->
            {reply, not_registered, S}
    end;
handle_leader_call({unregister, Name}, _From, S, _E) ->
    case ngproc_lib:unregister(Name) of
        unregistered ->
            {reply, ok, {unregister, Name}, S};
        not_registered ->
            {reply, not_registered, S}
    end;
handle_leader_call(Msg, _From, S, _E) ->
    ?INFO("Unexpected leader call: ~p", [Msg]),
    {noreply, S}.


from_leader({register, _Name, _Pid, _Resolver}, _S, _E) ->
    erlang:error(not_implemented);
from_leader({reregister, _Name, _NewPid}, _S, _E) ->
    erlang:error(not_implemented);
from_leader({unregister, _Name}, _S, _E) ->
    erlang:error(not_implemented);
from_leader(Msg, S, _E) ->
    ?ERR("Unexpected broadcast from leader: ~p", [Msg]),
    {noreply, S}.

handle_leader_cast(_Msg, S, _E) ->
    {noreply, S}.

handle_call(_Req, _From, S, _E) ->
    {noreply, S}.

handle_cast(_Msg, S, _E) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

handle_DOWN(_Node, State, _E) ->
    {ok, State}.

terminate(_, _S) ->
    ok.

code_change(_OldVsn, S, _E, _Extra) ->
    {ok, S}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
