%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et

-module(rebar_relx_ext).

-export([do/2,
         opt_spec_list/0,
         format_error/1]).

-ifdef(TEST).
-export([merge_overlays/1]).
-endif.

-define(DEFAULT_RELEASE_DIR, "rel").

-include_lib("providers/include/providers.hrl").

%% ===================================================================
%% Public API
%% ===================================================================
-spec do(atom(), rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(Provider, State) ->
    dbg:tracer(),
    dbg:tpl(rlx_release, realize, cx),
    dbg:p(all, [c]),
    {Opts, _} = rebar_state:command_parsed_args(State),
    RelxConfig = read_relx_config(State, Opts),

    ProfileString = rebar_dir:profile_dir_name(State),
    ExtraOverlays = [{profile_string, ProfileString}],

    CurrentProfiles = rebar_state:current_profiles(State),
    RelxMode = case lists:member(prod, CurrentProfiles) of
                   true ->
                       [{mode, prod}];
                   false ->
                       []
               end,
    DefaultOutputDir = filename:join(rebar_dir:base_dir(State), ?DEFAULT_RELEASE_DIR),
    RelxConfig1 = RelxMode ++ [output_dir(DefaultOutputDir, Opts),
                               {overlay_vars_values, ExtraOverlays},
                               {overlay_vars, [{base_dir, rebar_dir:base_dir(State)} | overlay_vars(Opts)]}
                               | merge_overlays(RelxConfig)],
    Args = [include_erts, system_libs, vm_args, sys_config],
    RelxConfig2 = maybe_obey_command_args(RelxConfig1, Opts, Args),
    RelxExtConfig = rebar_state:get(State, relx_ext, []),
    {ok, RelxExtState} = rlx_ext_config:to_state(RelxConfig2, RelxExtConfig),

    Providers = rebar_state:providers(State),
    Cwd = rebar_state:dir(State),

    rebar_hooks:run_project_and_app_hooks(Cwd, pre, Provider, Providers, State),

    Clusters = clusters_to_build(Provider, Opts, RelxExtState),

    case Provider of
        Provider when Provider == clusup; Provider == clusuptar ->
            [{Cluster, ToVsn}|_] = Clusters,
            UpFromVsn = proplists:get_value(upfrom, Opts, undefined),
            case Provider of
                clusup ->
                    relx_ext:build_clusup(Cluster, ToVsn, UpFromVsn, RelxExtState);
                clusuptar ->
                    relx_ext:build_clusuptar(Cluster, ToVsn, UpFromVsn, RelxExtState)
            end;
        _ ->
            parallel_run(Provider, Clusters, all_apps(State), RelxExtState)
    end,

    rebar_hooks:run_project_and_app_hooks(Cwd, post, Provider, Providers, State),

    {ok, State}.

read_relx_config(State, Options) ->
    ConfigFile = proplists:get_value(config, Options, []),
    case ConfigFile of
        "" ->
            ConfigPath = filename:join([rebar_dir:root_dir(State), "relx.config"]),
            case {rebar_state:get(State, relx, []), file:consult(ConfigPath)} of
                {[], {ok, Config}} ->
                    rebar_log:log(debug, "Configuring releases with relx.config", []),
                    Config;
                {Config, {error, enoent}} ->
                    rebar_log:log(debug, "Configuring releases the {relx, ...} entry from rebar.config", []),
                    Config;
                {_, {error, Reason}} ->
                    erlang:error(?PRV_ERROR({config_file, "relx.config", Reason}));
                {RebarConfig, {ok, _RelxConfig}} ->
                    rebar_log:log(warn, "Found conflicting relx configs, configuring releases"
                          " with rebar.config", []),
                    RebarConfig
            end;
        ConfigFile ->
            case file:consult(ConfigFile) of
                {ok, Config} ->
                    rebar_log:log(debug, "Configuring releases with: ~ts", [ConfigFile]),
                    Config;
                {error, Reason} ->
                    erlang:error(?PRV_ERROR({config_file, ConfigFile, Reason}))
            end
    end.

merge_relx_ext(Relx, RelxState, State) ->
    RelxExtConfig = rebar_state:get(State, relx_ext, []),
    RlxReleaseMap = rlx_releases(RelxState),
    lists:foldl(
      fun({release, {ReleaseName, ReleaseVsn}, SubReleases}, RelxStateAcc) ->
              case release(ReleaseName, ReleaseVsn, SubReleases, [], RlxReleaseMap, Relx, RelxStateAcc) of
                  {ok, RelxStateAcc1} ->
                      RelxStateAcc1;
                  {error, Reason} ->
                      erlang:error(?PRV_ERROR({invalid_release, ReleaseName, ReleaseVsn, Reason})),
                      RelxStateAcc
              end;
         ({release, {ReleaseName, ReleaseVsn}, SubReleases, Config}, RelxStateAcc) ->
              case release(ReleaseName, ReleaseVsn, SubReleases, Config, RlxReleaseMap, Relx, RelxStateAcc) of
                  {ok, RelxStateAcc1} ->
                      RelxStateAcc1;
                  {error, Reason} ->
                      erlang:error(?PRV_ERROR({invalid_release, ReleaseName, ReleaseVsn, Reason})),
                      RelxStateAcc
              end;
         (_Other, Acc) ->
              Acc
      end, RelxState, RelxExtConfig).

release(ReleaseName, ReleaseVsn, SubReleases, Config, RlxReleaseMap, Relx, RelxState) ->
    Result = 
        lists:map(
          fun(SubReleaseName) when is_atom(SubReleaseName) ->
                  case get_last_release(SubReleaseName, RlxReleaseMap) of
                      {ok, SubReleaseVsn} ->
                          goals(SubReleaseName, SubReleaseVsn, RelxState);
                      {error, Reason} ->
                          {error, Reason}
                  end;
             ({SubReleaseName, SubReleaseVsn}) when is_atom(SubReleaseName) ->
                  goals(SubReleaseName, SubReleaseVsn, RelxState);
             (SubRelease) ->
                  {error, {invalid_sub_release, SubRelease}}
          end, SubReleases),
    case rebar3_relx_extra_lib:split_fails(
           fun({SubReleaseName, SubRelaseVsn, SubGoals}, {SubReleasesAcc, GoalsAcc}) ->
                   GoalsAcc1 = ordsets:union(ordsets:from_list(SubGoals), GoalsAcc),
                   SubReleasesAcc1 = [{SubReleaseName, SubRelaseVsn}|SubReleasesAcc],
                   {SubReleasesAcc1, GoalsAcc1}
           end, {[], ordsets:new()}, Result) of
        {ok, {SubReleases1, Goals}} ->
            InitConfig = 
                lists:map(
                  fun({Key, _}) ->
                          {Key, proplists:get_value(Key, Relx)}
                  end, Config),
            add_release_config(
              ReleaseName, ReleaseVsn, Goals, [{ext, SubReleases1}, {init_config, InitConfig}|Config], RelxState);
        {error, Reason} ->
            {error, Reason}
    end.

add_release_config(ReleaseName, ReleaseVsn, Goals, Config, RlxState) ->
    Release0 = rlx_release:new(ReleaseName, ReleaseVsn),
    Release1 = rlx_release:parsed_goals(Release0, Goals),
    Release2 = rlx_release:config(Release1, Config),
    {ok, rlx_state:add_configured_release(RlxState, Release2)}.

get_last_release(SubReleaseName, RlxReleaseMap) ->
   case maps:find(SubReleaseName, RlxReleaseMap) of
       {ok, [ReleaseVsn|_T]} ->
           {ok, ReleaseVsn};
       error ->
           {error, {no_subrelease, SubReleaseName}}
   end.

goals(ReleaseName, ReleaseVsn, RelxState) ->
    try rlx_state:get_configured_release(RelxState, ReleaseName, ReleaseVsn) of
        Release ->
            {ok, {ReleaseName, ReleaseVsn, rlx_release:goals(Release)}}
    catch
        _:not_found ->
            {error, {ReleaseName, ReleaseVsn, not_found}}
    end.

rlx_releases(State) ->
    Releases = rlx_state:configured_releases(State),
    RelVsns = maps:keys(Releases),
    RlxReleaseMap = 
        lists:foldl(
          fun({ReleaseName, ReleaseVsn}, Acc) ->
                  ReleaseVsns = maps:get(ReleaseName, Acc, []),
                  ReleaseVsns1 = [ReleaseVsn|ReleaseVsns],
                  maps:put(ReleaseName, ReleaseVsns1, Acc)
          end, maps:new(), RelVsns),
    maps:map(
      fun(_ReleaseName, ReleaseVsns) ->
              lists:sort(
                fun(R1, R2) ->
                        ec_semver:gte(R1, R2)
                end, ReleaseVsns)
      end, RlxReleaseMap).

-spec format_error(any()) -> iolist().
format_error(unknown_release) ->
    "Option --relname is missing";
format_error(unknown_vsn) ->
    "Option --relvsn is missing";
format_error(all_relup) ->
    "Option --all can not be applied to `relup` command";
format_error({config_file, Filename, Error}) ->
    io_lib:format("Failed to read config file ~ts: ~p", [Filename, Error]);
format_error(Error) ->
    io_lib:format("~p", [Error]).

parallel_run(Provider, [{ClusName, ClusVsn}], AllApps, RelxState) ->
    case rlx_ext_state:get_cluster(RelxState, ClusName, ClusVsn) of
        {ok, Cluster} ->
            parallel_run(Provider, [Cluster], AllApps, RelxState);
        error ->
            erlang:error(?PRV_ERROR({no_cluster_for, ClusName, ClusVsn}))
    end;
parallel_run(clusrel, [Cluster], AllApps, RelxState) ->
    relx_ext:build_clusrel(Cluster, AllApps, RelxState);
parallel_run(clustar, [Cluster], AllApps, RelxState) ->
    relx_ext:build_clustar(Cluster, AllApps, RelxState);
parallel_run(Provider, Releases, AllApps, RelxState) ->
    rebar_parallel:queue(Releases, fun rel_worker/2, [Provider, AllApps, RelxState], fun rel_handler/2, []).

rel_worker(Release, [Provider, Apps, RelxState]) ->
    try
        case Provider of
            release ->
                relx:build_release(Release, Apps, RelxState);
            tar ->
                relx:build_tar(Release, Apps, RelxState)
        end
    catch
        error:Error ->
            {Release, Error}
    end.

rel_handler({{Name, Vsn}, {error, {Module, Reason}}}, _Args) ->
    rebar_log:log(error, "Error building release ~ts-~ts:~n~ts~ts", [Name, Vsn, rebar_utils:indent(1),
                                                       Module:format_error(Reason)]),
    ok;
rel_handler({{Name, Vsn}, Other}, _Args) ->
    rebar_log:log(error, "Error building release ~ts-~ts:~nUnknown return value: ~p", [Name, Vsn, Other]),
    ok;
rel_handler({ok, _}, _) ->
    ok.

clusters_to_build(Provider, Opts, RelxExtState)->
    case proplists:get_value(all, Opts, undefined) of
        undefined ->
            case proplists:get_value(relname, Opts, undefined) of
                undefined ->
                    case rlx_ext_state:default_cluster(RelxExtState) of
                        {ok, Cluster} ->
                            [Cluster];
                        {error, Reason} ->
                            erlang:error(?PRV_ERROR(Reason))
                    end;
                R ->
                    ClusName = list_to_atom(R),
                    case proplists:get_value(relvsn, Opts, undefined) of
                        undefined ->
                            case rlx_ext_state:lastest_cluster(RelxExtState, ClusName) of
                                {ok, Cluster} ->
                                    [Cluster];
                                {error, Reason} ->
                                    erlang:error(?PRV_ERROR(Reason))
                            end;
                        ClusVsn ->
                            [{ClusName, ClusVsn}]
                    end
            end;
        true when Provider =:= clusup; Provider =:= clusuptar ->
            erlang:error(?PRV_ERROR(all_clusup));
        true ->
            maps:to_list(rlx_ext_state:lastest_clusters(RelxExtState))
    end.

%% takes a map of relx configured releases and returns a list of the highest
%% version for each unique release name
-spec highest_unique_releases(rlx_state:releases()) -> [{atom(), string() | undefined}].
highest_unique_releases(Releases) ->
    Unique = maps:fold(fun({Name, Vsn}, _, Acc) ->
                               update_map_if_higher(Name, Vsn, Acc)
                       end, #{}, Releases),
    maps:to_list(Unique).

update_map_if_higher(Name, Vsn, Acc) ->
    maps:update_with(Name, fun(Vsn1) ->
                                   case rlx_util:parsed_vsn_lte(rlx_util:parse_vsn(Vsn1),
                                                                rlx_util:parse_vsn(Vsn)) of
                                       true ->
                                           Vsn;
                                       false ->
                                           Vsn1
                                   end
                           end, Vsn, Acc).

%% Don't override output_dir if the user passed one on the command line
output_dir(DefaultOutputDir, Options) ->
    {output_dir, proplists:get_value(output_dir, Options, DefaultOutputDir)}.

merge_overlays(Config) ->
    {Overlays, Others} =
        lists:partition(fun(C) when element(1, C) =:= overlay -> true;
                           (_) -> false
                        end, Config),
    %% Have profile overlay entries come before others to match how profiles work elsewhere
    NewOverlay = lists:flatmap(fun({overlay, Overlay}) -> Overlay end, lists:reverse(Overlays)),
    [{overlay, NewOverlay} | Others].

overlay_vars(Opts) ->
    case proplists:get_value(overlay_vars, Opts) of
        undefined ->
            [];
        [] ->
            [];
        FileName when is_list(FileName) ->
            [FileName]
    end.

maybe_obey_command_args(RelxConfig, Opts, Args) ->
    lists:foldl(
        fun(Opt, Acc) ->
                 case proplists:get_value(Opt, Opts) of
                     undefined ->
                         Acc;
                     V ->
                         lists:keystore(Opt, 1, Acc, {Opt, V})
                 end
        end, RelxConfig, Args).

%% Returns a map of all apps that are part of the rebar3 project.
%% This means the project apps and dependencies but not OTP libraries.
-spec all_apps(rebar_state:t()) -> #{atom() => rlx_app_info:t()}.
all_apps(State) ->
    maps:merge(app_infos_to_relx(rebar_state:project_apps(State), project),
               app_infos_to_relx(rebar_state:all_deps(State), dep)).

%%

-spec app_infos_to_relx([rlx_app_info:t()], rlx_app_info:app_type()) -> #{atom() => rlx_app_info:t()}.
app_infos_to_relx(AppInfos, AppType) ->
    lists:foldl(fun(AppInfo, Acc) ->
                        Acc#{binary_to_atom(rebar_app_info:name(AppInfo), utf8)
                             => app_info_to_relx(rebar_app_info:app_to_map(AppInfo), AppType)}
                end, #{}, AppInfos).

app_info_to_relx(#{name := Name,
                   vsn := Vsn,
                   applications := Applications,
                   included_applications := IncludedApplications,
                   dir := Dir,
                   link := false}, AppType) ->
    rlx_app_info:new(Name, Vsn, Dir, Applications, IncludedApplications, AppType).

-spec opt_spec_list() -> [getopt:option_spec()].
opt_spec_list() ->
    [{all, undefined, "all",  boolean,
      "If true runs the command against all configured  releases"},
    {relname,  $n, "relname",  string,
      "Specify the name for the release that will be generated"},
     {relvsn, $v, "relvsn", string, "Specify the version for the release"},
     {upfrom, $u, "upfrom", string,
      "Only valid with relup target, specify the release to upgrade from"},
     {output_dir, $o, "output-dir", string,
      "The output directory for the release. This is `./` by default."},
     {help, $h, "help", undefined,
      "Print usage"},
     {lib_dir, $l, "lib-dir", string,
      "Additional dir that should be searched for OTP Apps"},
     {dev_mode, $d, "dev-mode", boolean,
      "Symlink the applications and configuration into the release instead of copying"},
     {include_erts, $i, "include-erts", string,
      "If true include a copy of erts used to build with, if a path include erts at that path. If false, do not include erts"},
     {override, $a, "override", string,
      "Provide an app name and a directory to override in the form <appname>:<app directory>"},
     {config, $c, "config", {string, ""}, "The path to a config file"},
     {overlay_vars, undefined, "overlay_vars", string, "Path to a file of overlay variables"},
     {vm_args, undefined, "vm_args", string, "Path to a file to use for vm.args"},
     {sys_config, undefined, "sys_config", string, "Path to a file to use for sys.config"},
     {system_libs, undefined, "system_libs", string, "Boolean or path to dir of Erlang system libs"},
     {version, undefined, "version", undefined, "Print relx version"},
     {root_dir, $r, "root", string, "The project root directory"}].
