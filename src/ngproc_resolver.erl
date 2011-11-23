%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc The default resolver and resolver behaviour for resolving
%% conflicting ngproc process registrations.
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
resolve(_Name, PidA, PidB) ->
    exit(PidA, kill),
    PidB.

%%====================================================================
%% Internal functions
%%====================================================================
