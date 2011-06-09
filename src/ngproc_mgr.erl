%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc
%%
%% Sync protocol:
%%   1) Leader wins election, sends {sync, Version=1, Tag}
%%   2) Candidates send {sync, Version=1, Tag, {node(), LocalNames}}
%%   3) Leader integrates result, sends {synced, Version=1, Tag,
%%   {ForeignNames, YourNames, ToBeResolved}} to each candidate
%%
%% @end
%%%-------------------------------------------------------------------
-module(ngproc_mgr).

-behaviour(gl_async_bully).

-include("ng_log.hrl").
-include("ngproc.hrl").
-include_lib("gl_async_bully/include/gl_async_bully_specs.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/2
         ,register/2
         ,reregister/2
         ,unregister/1
        ]).

%% gl_async_bully callbacks
-export([init/1,
         elected/2,
         surrendered/3,
         handle_leader_call/4,
         handle_leader_cast/3,
         from_leader/3,
         handle_call/4,
         handle_cast/3,
         handle_DOWN/3,
         handle_info/3,
         terminate/3,
         code_change/4
        ]).

-record(state, {tid,
                sync_tag,
                resolver,
                name}).

-type sync_msg() :: {sync, {'v1',
                            Tag::reference(),
                            FromNode::node()},
                     sync_msg_type()}.

-type sync_msg_type() ::
        'sync_names' |
        {'sync_names_reply', {'v1', [ngproc:nameinfo()]}}.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec start_link() -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
%% @end
%%--------------------------------------------------------------------

-spec register(ngproc:name(), pid()) ->
                      'ok' | {'duplicate', pid()}.
register(Name, Pid) when is_pid(Pid)->
    %% Local check for existing registration - bail out early?
    case ngproc_lib:whereis(Name) of
        undefined ->
            gl_async_bully:leader_call(?MODULE, {register, Name, Pid});
        Pid ->
            ok;
        OldPid when is_pid(OldPid) ->
            {duplicate, OldPid}
    end.

-spec reregister(ngproc:name(), pid()) -> 'ok' | {'error', 'not_registered'}.
reregister(Name, NewPid) when is_pid(NewPid) ->
    gl_async_bully:leader_call(?MODULE, {reregister, Name, NewPid}).

-spec unregister(ngproc:name()) -> 'ok'.
unregister(Name) ->
    gl_async_bully:leader_call(?MODULE, {unregister, Name}).


-spec start_link(Name::atom(), ngproc:resolver()) -> term().
start_link(Name, Resolver) ->
    CandNodes = ngproc_app:config(cluster_nodes),
    gl_async_bully:start_link(?MODULE, CandNodes, [],
                          ?MODULE, [Name, Resolver], []).

%%====================================================================
%% gl_async_bully callbacks
%%====================================================================

init([Name, Resolver]) ->
    Tid = ngproc_lib:init(),
    net_kernel:monitor_nodes(true, {nodetype, visiable}),
    {ok, #state{tid=Tid, resolver=Resolver, name=Name}}.

%% Won a complete election
elected(S = #state{}, _E) ->
    %% XXX - blindly overwriting old sync tag - valid?
    SyncTag = make_ref(),
    {ok, {sync, {v1, SyncTag, node()}, sync_names}, S#state{sync_tag=SyncTag}};
%% Captured a new candidate
elected(S = #state{sync_tag=SyncTag}, _E, _Node) when is_reference(SyncTag) ->
    %% XXX - ok to just send old-ish sync tag to newly captured candidate?
    {ok, {sync, {v1, SyncTag, node()}, sync_names}, S}.

%% non-leader -- counterpart to elected
surrendered(S = #state{},
            {sync, {v1, SyncTag, _LeaderNode}, sync_names}, E) ->
    leader_pid(S, E) ! sync_names_reply(SyncTag),
    {ok, S};
surrendered(S = #state{}, Sync, _E) ->
    ?WARN("Unknown sync message from leader: ~p", [Sync]),
    {ok, S}.

%% leader ops
handle_leader_call({register, Name, Pid}, _From, S = #state{}, _E) ->
    case ngproc_lib:register(Name, Pid) of
        registered ->
            {reply, ok, {register, Name, Pid}, S};
        {duplicate, CanonicalPid} ->
            {reply,
             {duplicate, CanonicalPid},
             {fixup, {Name, CanonicalPid}},
             S}
    end;
handle_leader_call({reregister, Name, NewPid}, _From, S, _E) ->
    case ngproc_lib:reregister(Name, NewPid) of
        {reregistered, _OldPid} ->
            {reply, ok, {reregister, Name, NewPid}, S};
        {error, not_registered} ->
            {reply, not_registered, S};
        no_change ->
            {reply, ok, S}
    end;
handle_leader_call({unregister, Name}, _From, S, _E) ->
    case ngproc_lib:unregister(Name) of
        unregistered ->
            {reply, ok, {unregister, Name}, S}
    end;
handle_leader_call(Msg, _From, S, _E) ->
    ?INFO("Unexpected leader call: ~p", [Msg]),
    {noreply, S}.

%% non-leader companion to handle_leader_call
from_leader({register, Name, Pid}, S, _E) ->
    case ngproc_lib:register(Name, Pid) of
        registered -> ok;
        {duplicate, OldPid} ->
            ?ERR("This should never happen -- duplicate reg from leader.~n"
                 "Name: ~p, pid: ~p (conflicts with ~p).",
                 [Name, Pid, OldPid])
    end,
    {noreply, S};
from_leader({reregister, Name, NewPid}, S, _E) ->
    case ngproc_lib:reregister(Name, NewPid) of
        no_change -> ok;
        {reregistered, _OldPid} -> ok;
        {error, not_registered} ->
            ?ERR("This should never happen -- "
                 "reregister from leader for unregistered name: ~p", [Name])
    end,
    {noreply, S};
from_leader({unregister, Name}, S, _E) ->
    ngproc_lib:unregister(Name),
    {noreply, S};

%% FIXUP
from_leader({fixup, {Name, Pid}}, S, _E) ->
    case ngproc_lib:reg_for(Name) of
        not_registered ->
            ngproc_lib:register(Name, Pid),
            ?WARN("Applied a fixup for ~p: registered ~p",
                  [Name, Pid]);
        Reg = #reg{} ->
            case ngproc_lib:reregister(Name, Pid, Reg) of
                no_change ->
                    ok;
                {reregistered, OldPid} ->
                    ?WARN("Applied a fixup for ~p: ~p now ~p",
                          [Name, OldPid, Pid]);
                {error, not_registered} ->
                    ?ERR("Got re-reg error on registered name. "
                         "Not supposed to be possible.", []),
                    ok
            end
    end,
    {noreply, S};

from_leader({remove_node, Node}, S, _E) ->
    ngproc_lib:remove_node(Node),
    {noreply, S};

from_leader(Msg, S, _E) ->
    ?ERR("Unexpected broadcast from leader: ~p", [Msg]),
    {noreply, S}.

handle_leader_cast(_Msg, S, _E) ->
    {noreply, S}.

handle_call(_Req, _From, S, _E) ->
    {noreply, S}.

handle_cast(_Msg, S, _E) ->
    {noreply, S}.


handle_info({nodedown, Node, _InfoList}, S, E) ->
    case gl_async_bully:my_role(E) of
        leader ->
            ngproc_lib:remove_node(Node),
            gl_async_bully:broadcast({from_leader,{remove_node, Node}}, E);
        _ -> ok
    end,
    {noreply, S};

handle_info({'DOWN', Ref, process, Pid, Reason}, S, _E) ->
    case ngproc_lib:ref_info(Ref) of
        {RefR, RegR} ->
            ngproc_lib:remove(RefR, RegR),
            {noreply, S};
        no_such_ref ->
            ?WARN("Got DOWN message (~p/~p)for unknown process (~p).",
                  [Ref, Reason, Pid]),
            {noreply, S}
    end;

handle_info({sync, {v1, SyncTag, FromNode}, Op},
            S = #state{sync_tag=SyncTag}, _E) ->
    handle_sync(FromNode, Op, S);
handle_info({sync, {v1, _WrongTag, FromNode}, _Op} = SyncMsg,
            S = #state{sync_tag=_SyncTag}, _E) ->
    ?WARN("~p send an unrecognized sync message: ~p.~n"
          "Morality core not installed.~n"
          "Firing up neurotoxin emitters.",
          [FromNode, SyncMsg]),
    {noreply, S};
handle_info(Msg, S, _E) ->
    ?WARN("Unexpected message: ~p", [Msg]),
    {noreply, S}.

handle_DOWN(_Node, State, _E) ->
    {ok, State}.

terminate(_, _S, _E) ->
    ok.

code_change(_OldVsn, S, _E, _Extra) ->
    {ok, S}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

leader_pid(#state{name=Name}, Election) ->
    {Name, gl_async_bully:leader_node(Election)}.

%% Leader handling sync from client
handle_sync(FromNode, {sync_names_reply, {v1, NameData}}, S) ->
    {_InSync,
     Update,
     Conflict,
     Dropped} = SyncResult = ngproc_lib:sync_with(FromNode, NameData),
    ?INFO("To Sync:~n~p~n", [SyncResult]),
    {noreply, S}.

sync_names_reply(SyncTag) ->
    {sync, {v1, SyncTag, node()},
     {sync_names_reply, ngproc_lib:local_names()}}.
