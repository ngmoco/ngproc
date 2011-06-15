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
%%-include_lib("gl_async_bully/include/gl_async_bully_specs.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/2
         ,register/3
         ,reregister/3
         ,unregister/2
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
         handle_info/3,
         terminate/3,
         code_change/3,
         format_status/2
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

-spec register(Server::atom(), ngproc:name(), pid()) ->
                      'ok' | {'duplicate', pid()}.
register(Server, Name, Pid) when is_pid(Pid)->
    %% Local check for existing registration - bail out early?
    case ngproc_lib:whereis(Name) of
        undefined ->
            gl_async_bully:leader_call(Server, {register, Name, Pid});
        Pid ->
            ok;
        OldPid when is_pid(OldPid) ->
            {duplicate, OldPid}
    end.

-spec reregister(Server::atom(), ngproc:name(), pid()) ->
                        'ok' | {'error', 'not_registered'}.
reregister(Server, Name, NewPid) when is_pid(NewPid) ->
    gl_async_bully:leader_call(Server, {reregister, Name, NewPid}).

-spec unregister(Server::atom(), ngproc:name()) -> 'ok'.
unregister(Server, Name) ->
    gl_async_bully:leader_call(Server, {unregister, Name}).

-spec start_link(Server::atom(), ngproc:resolver()) ->
                        {'ok', pid()} |
                        {'error', Reason::term()} |
                        'ignore'.
start_link(Server, Resolver) ->
    CandNodes = ngproc_app:config(cluster_nodes),
    gl_async_bully:start_link(Server, ?MODULE, [Server, Resolver], CandNodes).

%%====================================================================
%% gl_async_bully callbacks
%%====================================================================

init([Name, Resolver]) ->
    Tid = ngproc_lib:init(),
    net_kernel:monitor_nodes(true, [{node_type, visable}]),
    {ok, #state{tid=Tid, resolver=Resolver, name=Name}}.

%% Won a complete election
elected(CI, S = #state{name=Name}) ->
    SyncTag = make_ref(),
    ?INFO("I ~p was elected. Starting new sync: ~p",
          [{Name, node()}, SyncTag]),
    ToDrop = ngproc_lib:dead_nodes(gl_async_bully:live_peers(CI)),
    [ ngproc_lib:remove_node(N) || N <- ToDrop ],
    %% XXX - inform clients of nodes to drop?
    %% XXX - blindly overwriting old sync tag - valid?
    {ok, {sync, {v1, SyncTag, node()}, sync_names},
     S#state{sync_tag=SyncTag}}.

surrendered(LeaderNode, _CI, S = #state{}) ->
    ?INFO("Acknowledged (possibly) new leader: ~p", [LeaderNode]),
    {ok, S#state{sync_tag=undefined}}.

%% leader ops
handle_leader_call({register, Name, Pid}, _From, _CI, S = #state{}) ->
    case ngproc_lib:register(Name, Pid) of
        registered ->
            {reply, ok, {register, Name, Pid}, S};
        {duplicate, CanonicalPid} ->
            {reply,
             {duplicate, CanonicalPid},
             {fixup, {Name, CanonicalPid}},
             S}
    end;
handle_leader_call({reregister, Name, NewPid}, _From, _CI, S) ->
    case ngproc_lib:reregister(Name, NewPid) of
        {reregistered, _OldPid} ->
            {reply, ok, {reregister, Name, NewPid}, S};
        {error, not_registered} ->
            {reply, not_registered, S};
        no_change ->
            {reply, ok, S}
    end;
handle_leader_call({unregister, Name}, _From, _CI, S = #state{}) ->
    case ngproc_lib:unregister(Name) of
        unregistered ->
            {reply, ok, {unregister, Name}, S}
    end;
handle_leader_call(Msg, _From, _CI, S) ->
    ?INFO("Unexpected leader call: ~p", [Msg]),
    {noreply, S}.

%% non-leader companion to handle_leader_call
from_leader({register, Name, Pid}, _CI, S) ->
    case ngproc_lib:register(Name, Pid) of
        registered -> ok;
        {duplicate, OldPid} ->
            ?ERR("This should never happen -- duplicate reg from leader.~n"
                 "Name: ~p, pid: ~p (conflicts with ~p).",
                 [Name, Pid, OldPid])
    end,
    {ok, S};
from_leader({reregister, Name, NewPid}, _CI, S) ->
    case ngproc_lib:reregister(Name, NewPid) of
        no_change -> ok;
        {reregistered, _OldPid} -> ok;
        {error, not_registered} ->
            ?ERR("This should never happen -- "
                 "reregister from leader for unregistered name: ~p", [Name])
    end,
    {ok, S};
from_leader({unregister, Name}, _CI, S) ->
    ngproc_lib:unregister(Name),
    {ok, S};

%% FIXUP
from_leader({fixups, Fixups}, _CI, S) ->
    [ fixup(F) || F <- Fixups ],
    {ok, S};

from_leader({remove_node, Node}, _CI, S) ->
    ngproc_lib:remove_node(Node),
    {ok, S};

from_leader({sync, {v1, SyncTag, FromNode}, Op},
            CI, S = #state{sync_tag=OurSyncTag})
  when OurSyncTag =:= SyncTag; OurSyncTag =:= undefined ->
    handle_sync(FromNode, Op, CI, S#state{sync_tag=SyncTag});
from_leader({sync, {v1, _WrongTag, FromNode}, _Op} = SyncMsg,
            _CI, S = #state{sync_tag=_SyncTag}) ->
    ?WARN("~p sent an unrecognized sync message: ~p.~n"
          "Morality core not installed.~n"
          "Firing up neurotoxin emitters.",
          [FromNode, SyncMsg]),
    {ok, S};

from_leader({'DOWN', Pid}, _CI, S) ->
    ngproc_lib:cleanup_pid(Pid),
    {ok, S};

from_leader(Msg, _CI, S) ->
    ?ERR("Unexpected broadcast from leader: ~p", [Msg]),
    {ok, S}.

handle_leader_cast({'DOWN', Pid}, _CI, S)
  when node(Pid) =/= node() ->
    ngproc_lib:cleanup_pid(Pid),
    {ok, {'DOWN', Pid}, S};

handle_leader_cast(_Msg, _CI, S) ->
    {ok, S}.

handle_call(_Req, _From, _CI, S) ->
    {noreply, S}.

handle_cast(_Msg, _CI, S) ->
    {ok, S}.


handle_info({nodedown, Node, _InfoList}, CI, S) ->
    case gl_async_bully:role(CI) of
        leader ->
            ngproc_lib:remove_node(Node),
            gl_async_bully:broadcast({from_leader,{remove_node, Node}}, CI);
        _ -> ok
    end,
    {ok, S};

handle_info({nodeup, _Node, _InfoList}, _CI, S) ->
    %% XXX - ignoring nodeup.
    {ok, S};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, CI, S)
  when node(Pid) =:= node() ->
    case gl_async_bully:role(CI) of
        leader ->
            ngproc_lib:cleanup_pid(Pid),
            {ok, {'DOWN', Pid}, S};
        _ ->
            ngproc_lib:cleanup_pid(Pid),
            gl_async_bully:leader_cast(CI, {'DOWN', Pid}),
            {ok, S}
    end;

handle_info({sync, {v1, SyncTag, FromNode}, Op},
            CI, S = #state{sync_tag=SyncTag}) ->
    handle_sync(FromNode, Op, CI, S#state{sync_tag=SyncTag});
handle_info({sync, {v1, _WrongTag, FromNode}, _Op} = SyncMsg,
            _CI, S = #state{sync_tag=_SyncTag}) ->
    ?WARN("~p sent an unrecognized sync message: ~p.~n"
          "Morality core not installed.~n"
          "Firing up neurotoxin emitters.",
          [FromNode, SyncMsg]),
    {ok, S};


handle_info(Msg, _CI, S) ->
    ?WARN("Unexpected message: ~p", [Msg]),
    {ok, S}.

terminate(_, _CI, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% Leader handling sync from client
handle_sync(FromNode, {sync_names_reply, NameData},
            CI, S = #state{resolver = R}) ->
    {SyncUS,
     {InSync,
      Updated,
      Resolved,
      Dropped}} = timer:tc(ngproc_lib, sync_with, [FromNode, NameData, R]),
      %% XXX - must rebroadcast sync decisions.
    ?INFO("Synced with ~p in ~pus:~n~p~n",
          [FromNode, SyncUS,
           [{accepted, length(InSync)},
            {updated, length(Updated)},
            {resolved, length(Resolved)},
            {removed, length(Dropped)}]]),
    gl_async_bully:to_follower(FromNode,
                               {fixups, Resolved}, CI),
    gl_async_bully:to_other_followers(FromNode,
                                      {fixups,
                                       InSync ++ Updated ++
                                           Resolved ++ Dropped},
                                      CI),
    {ok, S};
handle_sync(FromNode, sync_names, _CI,
            State = #state{name = Name, sync_tag=SyncTag}) ->
    erlang:send({Name, FromNode},
                sync_names_reply(SyncTag)),
    {ok, State}.


sync_names_reply(SyncTag) ->
    {sync, {v1, SyncTag, node()},
     {sync_names_reply, ngproc_lib:local_names()}}.

fixup({register, Name, Pid}) ->
    case ngproc_lib:reg_for(Name) of
        not_registered ->
            ngproc_lib:register(Name, Pid),
            %%?WARN("Applied a fixup for ~p: registered ~p",
            %%      [Name, Pid]),
            ok;
        Reg = #reg{} ->
            case ngproc_lib:reregister(Name, Pid, Reg) of
                no_change ->
                    ok;
                {reregistered, _OldPid} ->
                    %%?WARN("Applied a fixup for ~p: ~p now ~p",
                    %%      [Name, OldPid, Pid]),
                    ok;
                {error, not_registered} ->
                    ?ERR("Got re-reg error on registered name ~p. "
                         "Not supposed to be possible.", [Name]),
                    ok
            end
    end;
fixup({unregister, Name}) ->
    ngproc_lib:unregister(Name).

format_status(_Fmt, S = #state{resolver = R}) ->
    [{resolver, R},
     {state, S}].
