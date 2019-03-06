%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2018, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 12 Nov 2018 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rebar3_prv_tar_ext).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-define(PROVIDER, tar).
-define(DEPS, [compile]).

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    State1 = rebar_state:add_provider(State, providers:create([{name, ?PROVIDER},
                                                               {module, ?MODULE},
                                                               {bare, true},
                                                               {deps, ?DEPS},
                                                               {example, "rebar3 tar"},
                                                               {short_desc, "Tar archive of release built of project."},
                                                               {desc, "Tar archive of release built of project."},
                                                               {opts, relx:opt_spec_list()}])),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    case rlx_ext_lib:update_rlx(State) of
        {ok, State1} ->
            Options = rebar_state:command_args(State1),
            OptionsList = split_options(Options, []),
            lists:foldl(
              fun(NOptions, {ok, Val}) ->
                      State2 = rebar_state:command_args(State1, NOptions),
                      case rebar_relx:do(rlx_prv_release, "tar_ext", ?PROVIDER, State2) of
                          {ok, _} ->
                              {ok, Val};
                          {error, Reason} ->
                              {error, Reason}
                      end;
                 (_, {error, Reason}) ->
                      {error, Reason}
              end, {ok, State}, OptionsList);
        {error, Reason} ->
            {error, Reason}
    end.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

split_options(["-n",ReleaseOptions|Rest], Acc) ->
    Releases = string:split(ReleaseOptions, "+", all),
    lists:map(
      fun(Release) ->
              lists:reverse(Acc) ++ ["-n",Release|Rest]
      end, Releases);
split_options([Value|Rest], Acc) ->
    split_options(Rest, [Value|Acc]);
split_options([], Acc) ->
    lists:reverse(Acc).
