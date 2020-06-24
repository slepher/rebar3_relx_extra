-module(rebar3_prv_compile_one).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include_lib("kernel/include/file.hrl").
-include_lib("providers/include/providers.hrl").

-define(PROVIDER, compile_one).
-define(ERLC_HOOK, erlc_compile).
-define(APP_HOOK, app_compile).
-define(DEPS, [lock]).

-define(DAG_VSN, 2).
-define(DAG_ROOT, "source").
-define(DAG_EXT, ".dag").

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Opts = [{application, $p, "app", string, "compile application"},
            {module,      $m, "module", string, "compile module"}],
    State1 = rebar_state:add_provider(
               State, providers:create([{name, ?PROVIDER},
                                        {module, ?MODULE},
                                        {bare, true},
                                        {deps, ?DEPS},
                                        {example, "rebar3 compile_one"},
                                        {short_desc, "Compile apps .app.src and .erl files."},
                                        {desc, "Compile apps .app.src and .erl files."},
                                        {opts, Opts}])),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    Application = proplists:get_value(application, Opts, undefined),
    Module = proplists:get_value(module, Opts, undefined),
    rebar_paths:set_paths([deps], State),

    Providers = rebar_state:providers(State),
    Deps = rebar_state:deps_to_build(State),

    ProjectApps = rebar_state:project_apps(State),

    CompileApp = compiled_app(Application, Deps, ProjectApps),
    case Module of
        undefined ->
            rebar_prv_compile:compile(State, Providers, CompileApp);
        _ ->
            Compilers = rebar_state:compilers(State),
            rebar_paths:set_paths([deps], State),
            run_compilers(Compilers, CompileApp, Module)
    end,
    {ok, State}.

-spec format_error(any()) -> iolist().
format_error({missing_artifact, File}) ->
    io_lib:format("Missing artifact ~ts", [File]);
format_error({bad_project_builder, Name, Type, Module}) ->
    io_lib:format("Error building application ~s:~n     Required project builder ~s function "
                  "~s:build/1 not found", [Name, Type, Module]);
format_error({unknown_project_type, Name, Type}) ->
    io_lib:format("Error building application ~s:~n     "
                  "No project builder is configured for type ~s", [Name, Type]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

run_compilers(Compilers, AppInfo, Module) ->
    lists:foreach(fun(CompilerMod) ->
                          run(CompilerMod, AppInfo, Module, undefined)
                  end, Compilers).

compiled_app(undefined, _Deps, [App]) ->
    App;
compiled_app(undefined, _Deps, _Apps) ->
    rebar_api:abort("multi apps in project", []);
compiled_app(Appname, Deps, Apps) ->
    case lists:filter(
           fun(AppInfo) ->
              Name = rebar_app_info:name(AppInfo),
                   Name == list_to_binary(Appname)
           end, Apps ++ Deps) of
        [] ->
            rebar_api:abort("no app named ~s", [Appname]);
        [App] ->
            App
    end.

run(CompilerMod, AppInfo, Module, Label) ->
    #{src_dirs := SrcDirs,
      include_dirs := InclDirs,
      src_ext := SrcExt,
      out_mappings := Mappings} = CompilerMod:context(AppInfo),

    BaseDir = rebar_utils:to_list(rebar_app_info:dir(AppInfo)),
    EbinDir = rebar_utils:to_list(rebar_app_info:ebin_dir(AppInfo)),

    BaseOpts = rebar_app_info:opts(AppInfo),
    AbsInclDirs = [filename:join(BaseDir, InclDir) || InclDir <- InclDirs],
    FoundFiles = rebar_compiler_dag_lib:find_source_files(BaseDir, SrcExt, SrcDirs, BaseOpts),

    OutDir = rebar_app_info:out_dir(AppInfo),
    AbsSrcDirs = [filename:join(BaseDir, SrcDir) || SrcDir <- SrcDirs],

    ModuleReleatedFiles = 
        lists:filter(
          fun(Filename) ->
                  Basename = filename:basename(Filename),
                  Rootname = filename:rootname(Basename),
                  Extname = filename:extension(Basename),
                  (Rootname == Module) and (Extname == SrcExt) 
          end, FoundFiles),
    G = rebar_compiler_dag_lib:init_dag(CompilerMod, AbsInclDirs, AbsSrcDirs, ModuleReleatedFiles, OutDir, EbinDir, Label),
    {{_FirstFiles, _FirstFileOpts}, {_RestFiles, Opts}} = CompilerMod:needed_files(G, ModuleReleatedFiles, Mappings, AppInfo),
    true = digraph:delete(G),

    compile_each(ModuleReleatedFiles, Opts, BaseOpts, Mappings, CompilerMod).

compile_each([], _Opts, _Config, _Outs, _CompilerMod) ->
    ok;
compile_each([Source | Rest], Opts, Config, Outs, CompilerMod) ->
    rebar_api:info("compiling file ~s", [Source]),
    case CompilerMod:compile(Source, Outs, Config, Opts) of
        ok ->
            rebar_api:debug("~tsCompiled ~ts", [rebar_utils:indent(1), filename:basename(Source)]);
        {ok, Warnings} ->
            rebar_base_compiler:report(Warnings),
            rebar_api:debug("~tsCompiled ~ts", [rebar_utils:indent(1), filename:basename(Source)]);
        skipped ->
            rebar_api:debug("~tsSkipped ~ts", [rebar_utils:indent(1), filename:basename(Source)]);
        Error ->
            NewSource = rebar_base_compiler:format_error_source(Source, Config),
            rebar_api:error("Compiling ~ts failed", [NewSource]),
            rebar_base_compiler:maybe_report(Error),
            rebar_api:debug("Compilation failed: ~p", [Error]),
            rebar_api:abort()
    end,
    compile_each(Rest, Opts, Config, Outs, CompilerMod).