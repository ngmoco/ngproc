%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc 
%% @end
%%%-------------------------------------------------------------------
-module(ngproc).

-include("ngproc.hrl").

-type name() :: number() | list() | tuple() | binary().
-type resolver() :: atom().
-type nameinfo() :: {name(), pid()}.
-type namedata() :: [nameinfo()].

-export_type([name/0
              ,resolver/0
              ,nameinfo/0
              ,namedata/0
             ]).

%% API
-export([whereis/1
         ,register/2
         ,reregister/2
         ,unregister/1
         ,registered_names/0
        ]).

%%====================================================================
%% API
%%====================================================================

-spec whereis(ngproc:name()) -> pid() | 'undefined'.
whereis(Name) ->
    ngproc_lib:whereis(Name).

-spec register(ngproc:name(), pid()) ->
                      'ok' | {duplicate, pid()}.
register(Name, Pid) ->
    ngproc_mgr:register(ngproc, Name, Pid).

-spec reregister(ngproc:name(), pid()) -> 'ok'.
reregister(Name, NewPid) ->
    ngproc_mgr:reregister(ngproc, Name, NewPid).

-spec unregister(ngproc:name()) -> 'ok'.
unregister(Name) ->
    ngproc_mgr:unregister(ngproc, Name).

-spec registered_names() -> namedata().
registered_names() ->
    ngproc_lib:all_names().

%%====================================================================
%% Internal functions
%%====================================================================
