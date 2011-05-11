%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc Functions for accessing the NAMES table
%%
%% {Name, Pid, Ref
%%
%% @end
%%%-------------------------------------------------------------------
-module(ngproc_lib).

-include("ngproc.hrl").

%% API
-export([whereis/1]).

%%====================================================================
%% API
%%====================================================================

whereis(Name) ->
    case ets:lookup(?NGPROC_NAMES, Name) of
        [{Name, Pid}] ->
            Pid;
        _ ->
            undefined
    end.

%%====================================================================
%% Internal functions
%%====================================================================

