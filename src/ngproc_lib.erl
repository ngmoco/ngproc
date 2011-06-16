%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc Functions for accessing the NAMES table
%%
%% As all of these functions access the local ETS table directly, and
%% many of them write to it, they assume they will only be called from
%% one process. Concurrent use is not supported.
%%
%% @end
%%%-------------------------------------------------------------------
-module(ngproc_lib).

-include("ngproc.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-compile({no_auto_import,[whereis/1, demonitor/1]}).

%% API
-export([init/0
         ,whereis/1
         ,name_info/1
         ,register/2
         ,reregister/2
         ,reregister/3
         ,unregister/1
         ,all_names/0
         ,local_names/0
         ,names_for_node/1
         ,remove/2
         ,reg_for/1
         ,sync_actions/2
         ,remove_node/1
         ,dead_nodes/1
         ,cleanup_pid/1
         ,compare/1
        ]).

-export([resolve_names/2]).

%%
%% NGPROC_NAMES table records:
%%   name -> pid :: {reg, Name, Pid}
%%   {Pid,Name} :: {rev, {Pid, Name}}
%%   pid -> monitor :: {mon, Pid, ref}

%%====================================================================
%% API
%%====================================================================

init() ->
    ets:new(?NGPROC_NAMES,
            [named_table, {keypos, 2}, protected, ordered_set]).

%% whereis, name_info and reg_for are the only concurrent safe(ish)
%% operations in ngproc_lib.
-spec whereis(ngproc:name()) -> pid() | 'undefined'.
whereis(Name) ->
    case name_info(Name) of
        {Name, Pid} ->
            Pid;
        not_registered ->
            undefined
    end.

-spec name_info(ngproc:name()) -> ngproc:nameinfo() | 'not_registered'.
name_info(Name) ->
    case reg_for(Name) of
        #reg{name=Name, pid=Pid} ->
            {Name, Pid};
        not_registered ->
            not_registered
    end.

-spec reg_for(ngproc:name()) -> #reg{} | 'not_registered'.
reg_for(Name) ->
    case ets:lookup(?NGPROC_NAMES, Name) of
        [R = #reg{}] ->
            R;
        [] -> not_registered
    end.

-spec register(ngproc:name(), pid()) ->
                      'registered' | {'duplicate', pid()}.
register(Name, Pid)
  when not is_reference(Name),
       not is_pid(Name) ->
    case ets:insert_new(?NGPROC_NAMES,
                        [#reg{name=Name, pid=Pid},
                         #rev{key={Pid, Name}}]) of
        true when node(Pid) =:= node() ->
            ensure_monitor(Pid),
            registered;
        true when node(Pid) =/= node() ->
            registered;
        false ->
            {duplicate, whereis(Name)}
    end.

reregister(Name, NewPid) ->
    reregister(Name, NewPid,
               reg_for(Name)).

-spec reregister(ngproc:name(), pid(),
                 #reg{} | 'undefined') ->
                        {'error', 'not_registered'} |
                        'no_change' |
                        {'reregistered', pid()}.
%% No previous reg.
reregister(_Name, _NewPid, not_registered) ->
    {error, not_registered};
%% No change
reregister(Name, NewPid,
           #reg{name=Name, pid=NewPid}) ->
    no_change;

%% Pid changes
reregister(Name, NewPid,
           #reg{name=Name, pid=OldPid}) ->
    WasOurs = node(OldPid) =:= node(),
    IsOurs = node(NewPid) =:= node(),
    %% Fixup #reg
    ets:update_element(?NGPROC_NAMES,
                       Name,
                       [{#reg.pid, NewPid}]),
    %% Fixup #rev
    ets:delete(?NGPROC_NAMES,
               {OldPid, Name}),
    ets:insert(?NGPROC_NAMES,
               #rev{key={NewPid, Name}}),
    %% Fixup #mon
    case WasOurs of
        true -> maybe_demonitor(OldPid);
        false -> ok
    end,
    case IsOurs of
        true -> ensure_monitor(NewPid);
        false -> ok
    end,
    %% All done
    {reregistered, OldPid}.

unregister(Name) ->
    case reg_for(Name) of
        #reg{name=Name, pid=OldPid} ->
            ets:delete(?NGPROC_NAMES, Name),
            ets:delete(?NGPROC_NAMES, {OldPid, Name}),
            maybe_demonitor(OldPid);
        not_registered -> ok
    end,
    unregistered.

-spec all_names() -> ngproc:namedata().
all_names() ->
    ets:select(?NGPROC_NAMES,
               [{list_to_tuple([reg, '$1', '$2']),
                 [],
                 [{{'$1','$2'}}]}]).
                %% ets:fun2ms(fun (#reg{name=Name,pid=Pid}) ->
                %%                    {Name,Pid}
                %%            end))}.

-spec local_names() -> ngproc:namedata().
local_names() -> names_for_node(node()).

-spec names_for_node(node()) -> ngproc:namedata().
names_for_node(Node) ->
    ets:select(?NGPROC_NAMES,
               [{list_to_tuple([reg, '$1', '$2']),
                 [{'=:=',{node,'$2'},Node}],
                 [{{'$1','$2'}}]}]).
               %% ets:fun2ms(fun ({reg, Name, Pid, '_'})
               %%                when node(Pid) =:= Node ->
               %%                    {Name, Pid}
               %%            end)).

remove(RefR = #rev{}, RegR = #reg{}) ->
    ets:delete_object(?NGPROC_NAMES, RefR),
    ets:delete_object(?NGPROC_NAMES, RegR),
    ok.

remove_name(Name) ->
    ets:delete(?NGPROC_NAMES, Name).
remove_names(Names) ->
    lists:map(fun remove_name/1, Names).

update_names(NameData) ->
    [ reregister(Name, NewPid)
      || {register, Name, NewPid} <- NameData ],
    ok.

resolve_name(Name, A, B, Resolver) when is_pid(A), is_pid(B) ->
    Pid = Resolver:resolve(Name, A, B),
    reregister(Name, Pid),
    {register, Name, Pid}.

resolve_names(NameData, Resolver) ->
    [ resolve_name(Name, A, B, Resolver)
      || {{Name, A}, {Name, B}} <- NameData ].

%% Missing - names local has that remote doesn't
%% Added - names remote has that we don't
%% Similar - names in common
-spec sync_actions(node(), ngproc:namedata()) ->
                       {InSync::[{register, ngproc:name(), pid()}],
                        Update::[{register, ngproc:name(), pid()}],
                        Conflict::[{Sync::ngproc:nameinfo(),
                                    Existing::ngproc:nameinfo()}],
                        Dropped::[{unregister, ngproc:name(), pid()}]}.
sync_actions(Node, NameData) ->
    Actions = lists:foldl(fun sync_one_name/2, [], NameData),
    {[{register, Name, Pid} || {same, {Name, Pid}} <- Actions],
     [{register, Name, Pid} || {accept, {Name, Pid}} <- Actions],
     [{NI, Conflict} || {resolve, NI, Conflict} <- Actions],
     [{unregister, Name}
      || Name <- stale_names(Node, NameData, names_for_node(Node))]
    }.

sync_one_name({Name, Pid} = NI, Acc) ->
    case reg_for(Name) of
        #reg{name=Name, pid=Pid} ->
            [{same, NI} | Acc];
        #reg{name=Name, pid=OtherPid}
          when node(OtherPid) =:= node(Pid) ->
            %% Different pid, but same node - nodes are authoritative
            %% for own registrations.
            [{accept, NI} | Acc];
        #reg{name=Name, pid=ConflictPid} ->
            [{resolve, NI, {Name, ConflictPid}} | Acc];
        not_registered ->
            [{accept, NI} | Acc]
    end.

stale_names(TheirNode, TheirNameData, OurNameData) ->
    Ours = sets:from_list([Name || {Name, P} <- OurNameData,
                                   node(P) =:= TheirNode]),
    Theirs = sets:from_list([Name || {Name, P} <- TheirNameData,
                            node(P) =:= TheirNode]),
    StaleNames = sets:subtract(Ours, Theirs),
    sets:to_list(StaleNames).

remove_node(Node) ->
    ets:select_delete(?NGPROC_NAMES,
                      [{list_to_tuple([reg, '_', '$1']),
                        [{'=:=',{node,'$1'},Node}],
                        [true]},
                       {list_to_tuple([rev, {'$1', '_'}]),
                        [{'=:=',{node,'$1'},Node}],
                        [true]}]).

-spec dead_nodes([node()]) -> [node()].
dead_nodes(NodesToKeep) ->
    %% this node() is never dead.
    ets:foldl(fun (#reg{pid=P}, DropSet) when node(P) =/= node() ->
                      Node = node(P),
                      case lists:member(Node, NodesToKeep) of
                          true -> DropSet;
                          false -> ordsets:add_element(Node, DropSet)
                      end;
                  (_, Acc) -> Acc
              end,
              ordsets:new(),
              ?NGPROC_NAMES).

%%====================================================================
%% Internal functions
%%====================================================================

ensure_monitor(Pid) when node(Pid) =:= node() ->
    case ets:lookup(?NGPROC_NAMES, Pid) of
        [#mon{pid=Pid}] ->
            ok;
        [] ->
            ets:insert(?NGPROC_NAMES,
                       #mon{pid=Pid,
                            ref=erlang:monitor(process, Pid)}),
            ok
    end.

-spec names(pid()) -> [ngproc:name()].
names(Pid) ->
    ets:select(?NGPROC_NAMES,
               [{list_to_tuple([rev, {'$1', '$2'}]),
                 [{'=:=','$1',{const, Pid}}],
                 ['$2']}]).

num_names(Pid) ->
    ets:select(?NGPROC_NAMES,
               [{list_to_tuple([rev, {'$1', '_'}]),
                 [{'=:=','$1',{const, Pid}}],
                 [true]}]).

cleanup_pid(Pid) ->
    Names = names(Pid),
    cleanup_pid(Pid, Names).

cleanup_pid(Pid, Names) ->
    [ begin
          ets:delete(?NGPROC_NAMES, Name),
          ets:delete(?NGPROC_NAMES, {Pid, Name}),
          ok
      end
      || Name <- Names],
    ets:delete(?NGPROC_NAMES, Pid),
    ok.

demonitor(Pid) ->
    case ets:lookup(?NGPROC_NAMES, Pid) of
        [#mon{pid=Pid, ref=Ref}] ->
            ets:delete(?NGPROC_NAMES, Pid),
            erlang:demonitor(Ref, [flush]),
            ok;
        [] ->
            ok
    end.

maybe_demonitor(Pid)
  when is_pid(Pid), node(Pid) =:= node() ->
    case names(Pid) of
        [] ->
            demonitor(Pid);
        _ ->
            ok
    end;
maybe_demonitor(Pid)
  when is_pid(Pid), node(Pid) =/= node() ->
    ok.

compare(ToNode) ->
    MyNames = all_names(),
    MN = dict:from_list(MyNames),
    MNs = sets:from_list(dict:fetch_keys(MN)),
    TheirNames = rpc:call(ToNode, ?MODULE, all_names, []),
    TN = dict:from_list(TheirNames),
    TNs = sets:from_list(dict:fetch_keys(TN)),
    [{missing_from, ToNode, sets:to_list(sets:subtract(MNs, TNs))},
     {missing_from, node(), sets:to_list(sets:subtract(TNs, MNs))},
     {different_values,
      lists:foldl(fun (K, Acc) ->
                        case {dict:fetch(K, MN),
                              dict:fetch(K, TN)} of
                            {V,V} -> Acc;
                            {V,Vp} -> [{K, V, Vp} | Acc]
                        end
                end,
                [],
                sets:to_list(sets:intersection(MNs,TNs)))}].
