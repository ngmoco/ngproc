%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc 
%% @end
%%%-------------------------------------------------------------------
-module(ngproc).

%% API
-export([whereis/1
         ,register/3
         ,reregister/2
         ,unregister/1
        ]).

%%====================================================================
%% API
%%====================================================================

-spec whereis(Name::term()) -> pid() | 'undefined'.
whereis(Name) ->
    ngproc_lib:whereis(Name).

-spec register(Name::term(), pid(), Resolver::atom()) -> 'ok' | {duplicate, pid()}.
register(Name, Pid, Resolver) ->
    ngproc_mgr:register(Name, Pid, Resolver).

-spec reregister(Name::term(), pid()) -> 'ok'.
reregister(Name, NewPid) ->
    ngproc_mgr:reregister(Name, NewPid).

-spec unregister(Name::term()) -> 'ok'.
unregister(Name) ->
    ngproc_mgr:unregister(Name).

%%====================================================================
%% Internal functions
%%====================================================================
