%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc
%% @end
%%%-------------------------------------------------------------------
-module(ngproc_resolver).

-include("ng_log.hrl").

%% API
-export([resolve/3]).

-callback resolve(ngproc:name(), pid(), pid()) -> pid().

%%====================================================================
%% API
%%====================================================================

-spec resolve(ngproc:name(), pid(), pid()) -> pid().
resolve(Name, PidA, PidB) ->
    exit(PidA, kill),
    PidB.

%%====================================================================
%% Internal functions
%%====================================================================
