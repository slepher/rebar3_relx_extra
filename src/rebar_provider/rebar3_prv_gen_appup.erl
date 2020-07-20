%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2020, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 27 Feb 2020 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rebar3_prv_gen_appup).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, gen_appup).
-define(DEPS, []).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},             % The 'user friendly' name of the task
            {module, ?MODULE},             % The module implementation of the task
            {bare, true},                  % The task can be run by the user, always true
            {deps, ?DEPS},                 % The list of dependencies
            {example, "rebar3 gen_appup"}, % How to use the plugin
            {opts, [                       % list of options understood by the plugin
                {relname, $n, "relname", string, "Release name"},
                {previous, $b, "previous", string, "location of the previous release"},
                {previous_version, $u, "upfrom", string, "version of the previous release"},
                {current, $c, "current", string, "location of the current release"},
                {target_dir, $t, "target_dir", string, "target dir in which to generate the .appups to"},
                {purge, $g, "purge", string, "per-module semi-colon separated list purge type "
                                             "Module=PrePurge/PostPurge, reserved name default for "
                                             "modules that are unspecified:"
                                             "(eg. default=soft;m1=soft/brutal;m2=brutal)"
                                             "default is brutal"}
            ]},
            {short_desc, "Build release of project ext."},
            {desc, "Build release of project ext"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    rebar_api:debug("opts: ~p", [Opts]),
    Name = rebar3_appup_utils:get_release_name(State),
    rebar_api:debug("release name: ~p", [Name]),
    CurrentRelPath = rebar3_appup_generate_lib:get_current_rel_path(State, Name),
    {CurrentName, CurrentVer} = get_clus_release_info(Name, CurrentRelPath),
    rebar_api:debug("current release, name: ~p, version: ~p", [CurrentName, CurrentVer]),
    PreviousRelPath = case proplists:get_value(previous, Opts, undefined) of
                          undefined -> CurrentRelPath;
                          P -> P
                      end,
    TargetDir = proplists:get_value(target_dir, Opts, undefined),
    rebar_api:debug("previous release: ~p", [PreviousRelPath]),
    rebar_api:debug("current release: ~p", [CurrentRelPath]),
    rebar_api:debug("target dir: ~p", [TargetDir]),
    %% deduce the previous version from the release path
    {PreviousName, _PreviousVer0} = get_clus_release_info(Name, PreviousRelPath),

    %% if a specific one was requested use that instead
    PreviousVer = case proplists:get_value(upfrom, Opts, undefined) of
                      undefined ->
                          rebar3_appup_generate_lib:deduce_previous_version(
                            Name, CurrentVer,CurrentRelPath, PreviousRelPath);
                      V -> V
                  end,
    rebar_api:debug("previous release, name: ~p, version: ~p",
                    [PreviousName, PreviousVer]),

    %% Run some simple checks
    true = rebar3_appup_utils:prop_check(CurrentVer =/= PreviousVer,
                      "current (~p) and previous (~p) release versions are the same",
                      [CurrentVer, PreviousVer]),
    true = rebar3_appup_utils:prop_check(CurrentName == PreviousName,
                      "current (~p) and previous (~p) release names are not the same",
                      [CurrentName, PreviousName]),

    %% Find all the apps that have been upgraded
    {AddApps0, UpgradeApps0, RemoveApps} = 
        rebar3_appup_generate_lib:get_apps(
          Name, PreviousRelPath, PreviousVer,
          CurrentRelPath, CurrentVer, State),
    
    rebar3_appup_generate_lib:generate_appups(
      CurrentRelPath, PreviousRelPath,  TargetDir, CurrentVer, Opts, AddApps0, UpgradeApps0, RemoveApps, State),
    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

get_clus_release_info(Name, Relpath) ->
    Filename = filename:join([Relpath, "releases", Name ++ ".clus"]),
    case file:consult(Filename) of
        {ok, [{cluster, _Name, Vsn, _, _}]} ->
            {Name, Vsn};
        _ ->
            rebar_api:abort("Failed to parse ~s~n", [Filename])
    end.

