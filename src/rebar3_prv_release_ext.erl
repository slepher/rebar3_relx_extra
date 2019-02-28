-module(rebar3_prv_release_ext).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, release_ext).
%-define(DEPS, [compile]).
-define(DEPS, []).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 rebar3 relx extra"}, % How to use the plugin
            {opts, relx:opt_spec_list()}, % list of options understood by the plugin
            {short_desc, "Build release of project ext."},
            {desc, "Build release of project ext"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    %dbg:tracer(),
    %dbg:tpl(erl_tar, create, cx),
    %dbg:p(all, [c]),
    case rlx_ext_lib:update_rlx(State) of
        {ok, State1} ->
            Options = rebar_state:command_args(State1),
            OptionsList = split_options(Options, []),
            lists:foldl(
              fun(NOptions, {ok, Val}) ->
                      State2 = rebar_state:command_args(State1, NOptions),
                      case rebar_relx:do(rlx_prv_release_ext, "release_ext", ?PROVIDER, State2) of
                          {ok, _} ->
                              {ok, Val};
                          {error, Reason} ->
                              {error, Reason}
                      end;
                 (_, {error, Reason}) ->
                      {error, Reason}
              end, {ok, State1}, OptionsList);
        {error, Reason} ->
            {error, Reason}
    end.

-spec format_error(any()) ->  iolist().
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

    
