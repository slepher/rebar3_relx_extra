%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2019, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 22 Feb 2019 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rebar3_relx_extra_lib).

%% API
-export([split_fails/3]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
split_fails(F, Init, Values) ->
    {Succs, Fails} = 
        lists:foldl(
          fun({ok, Value}, {Acc, FailsAcc}) ->
                  {F(Value, Acc), FailsAcc};
             (ok, {Acc, FailsAcc}) ->
                  {F(ok, Acc), FailsAcc};
             ({error, Reason}, {Acc, FailsAcc}) ->
                  {Acc, [Reason|FailsAcc]}
          end, {Init, []}, Values),
    case Fails of
        [] ->
            {ok, Succs};
        Fails ->
            {error, Fails}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
