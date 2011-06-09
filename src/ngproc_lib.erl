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

-compile({no_auto_import,[whereis/1]}).

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
         ,ref_info/1
         ,remove/2
         ,reg_for/1
         ,sync_with/2
         ,remove_node/1
        ]).

%%====================================================================
%% API
%%====================================================================

init() ->
    ets:new(?NGPROC_NAMES,
                  [named_table, {keypos, #reg.name}, protected, ordered_set]).

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
  when node(Pid) =/= node(),
       not is_reference(Name) ->
    case ets:insert_new(?NGPROC_NAMES,
                        [#reg{name=Name, pid=Pid}]) of
        true ->
            registered;
        false ->
            {duplicate, whereis(Name)}
    end;
register(Name, Pid)
  when node(Pid) =:= node(),
       not is_reference(Name) ->
    %% XXX monitoring before success? why
    Ref = erlang:monitor(process, Pid),
    case ets:insert_new(?NGPROC_NAMES,
                        [#reg{name=Name, pid=Pid, ref=Ref},
                         #ref{r=Ref, name=Name}]) of
        true ->
            registered;
        false ->
            erlang:demonitor(Ref, [flush]),
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
           #reg{name=Name, pid=OldPid, ref=Ref}) ->
    case node(OldPid) =:= node() of
        true when is_reference(Ref) ->
            ets:delete(?NGPROC_NAMES, Ref),
            erlang:demonitor(Ref, [flush]);
        _ -> ok
    end,
    case node(NewPid) =:= node() of
        true ->
            NewRef = erlang:monitor(process, NewPid),
            ets:update_element(?NGPROC_NAMES,
                               Name,
                               [{#reg.pid, NewPid},
                                {#reg.ref, NewRef}]),
            ets:insert(?NGPROC_NAMES, #ref{r=NewRef, name=Name});
        false ->
            ets:update_element(?NGPROC_NAMES,
                               Name,
                               [{#reg.pid, NewPid},
                                {#reg.ref, undefined}])
    end,
    {reregistered, OldPid}.

unregister(Name) ->
    case reg_for(Name) of
        #reg{name=Name, pid=OldPid, ref=Ref}
          when is_reference(Ref), node(OldPid) =:= node() ->
            erlang:demonitor(Ref, [flush]),
            true = ets:delete(?NGPROC_NAMES, Name);
        #reg{} ->
            true = ets:delete(?NGPROC_NAMES, Name);
        not_registered -> ok
    end,
    unregistered.

-spec all_names() -> {'v1', ngproc:namedata()}.
all_names() ->
    {v1,
     ets:select(?NGPROC_NAMES,
                [{list_to_tuple([reg, '$1', '$2', '_']),
                  [],
                  [{{'$1','$2'}}]}])}.
                %% ets:fun2ms(fun (#reg{name=Name,pid=Pid}) ->
                %%                    {Name,Pid}
                %%            end))}.

-spec local_names() -> ngproc:namedata().
local_names() -> names_for_node(node()).

-spec names_for_node(node()) -> ngproc:namedata().
names_for_node(Node) ->
    ets:select(?NGPROC_NAMES,
               [{list_to_tuple([reg, '$1', '$2', '_']),
                 [{'=:=',{node,'$2'},Node}],
                 [{{'$1','$2'}}]}]).
               %% ets:fun2ms(fun ({reg, Name, Pid, '_'})
               %%                when node(Pid) =:= Node ->
               %%                    {Name, Pid}
               %%            end)).

-spec ref_info(reference()) ->
                      'no_such_ref' | {#ref{}, #reg{}}.
ref_info(Ref) when is_reference(Ref), node(Ref) =:= node() ->
    case ets:lookup(?NGPROC_NAMES, Ref) of
        [RefR = #ref{r=Ref, name=Name}] ->
            case ets:lookup(?NGPROC_NAMES, Name) of
                [RegR = #reg{name=Name}] ->
                    {RefR, RegR};
                _ ->
                    exit({missing_reg_for, RefR})
            end;
        _ ->
            no_such_ref
    end.

remove(RefR, RegR) ->
    ets:delete_object(?NGPROC_NAMES, RefR),
    ets:delete_object(?NGPROC_NAMES, RegR),
    ok.

%% Missing - names local has that remote doesn't
%% Added - names remote has that we don't
%% Similar - names in common
-spec sync_with(node(), ngproc:namedata()) ->
                       {InSync::ngproc:namedata(),
                        Update::ngproc:namedata(),
                        Conflict::[{Sync::ngproc:nameinfo(),
                                    Existing::ngproc:nameinfo()}],
                        Dropped::ngproc:namedata()}.
sync_with(Node, NameData) ->
    Actions = lists:foldl(fun sync_one_name/2, [], NameData),
    {[NI || {same, NI} <- Actions],
     [NI || {accept, NI} <- Actions],
     [{NI, Conflict} || {resolve, NI, Conflict} <- Actions],
     stale_names(NameData, names_for_node(Node))
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

stale_names(TheirNameData, OurNameData) ->
    OurNames = dict:from_list(OurNameData),
    TheirNames = dict:from_list(TheirNameData),
    Ours = sets:from_list(dict:fetch_keys(OurNames)),
    Theirs = sets:from_list(dict:fetch_keys(TheirNames)),
    StaleNames = sets:subtract(Ours, Theirs),
    [ dict:fetch(Name, OurNames) || Name <- set:to_list(StaleNames) ].

remove_node(Node) ->
    ets:select_delete(?NGPROC_NAMES,
                      [{list_to_tuple([reg, '_', '$1', '_']),
                        [{'=:=',{node,'$1'},Node}],
                        [true]}]).

%%====================================================================
%% Internal functions
%%====================================================================
