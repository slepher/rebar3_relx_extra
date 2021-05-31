%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2019, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 28 Feb 2019 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(relx_ext_lib).

-include_lib("sasl/src/systools.hrl").
-include_lib("kernel/include/file.hrl").


%% API
-export([update_lastest_vsn/3]).
-export([split_fails/3]).
-export([path/0, path/1]).
-export([application_files/3, application_files/4]).
-export([add_file/4]).
%%%===================================================================
%%% API
%%%===================================================================
update_lastest_vsn(Name, Vsn, Map) ->
    case maps:find(Name, Map) of
        {ok, LastestVsn} ->
            case rlx_util:parsed_vsn_lte(rlx_util:parse_vsn(LastestVsn), rlx_util:parse_vsn(Vsn)) of
                true ->
                    maps:put(Name, Vsn, Map);
                false ->
                    Map
            end;
        error ->
            maps:put(Name, Vsn, Map)
    end.

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

path() ->
    path([]).

path(Flags) ->
    Path0 = get_path(Flags),
    Path1 = mk_path(Path0),
    make_set(Path1 ++ code:get_path()).

application_files(Name, Vsn, Path) ->
    application_files(Name, Vsn, Path, []).

application_files(Name, Vsn, Path, Flags) ->
    case systools_make:read_application(to_list(Name), Vsn, Path, []) of
        {ok, App} ->
            Files = app_files(App, Name, Vsn, Flags),
            {ok, Files};
        {error, Reason} ->
            {error, Reason}
    end.
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
app_files(#application{modules = Modules, dir = AppDir}, Name, Vsn, Flags) ->
    ToDir = filename:join("lib", to_list(Name) ++ "-" ++ Vsn),
    ADir = appDir(AppDir),
    Files0 = 
        lists:foldl(
          fun(Module, Acc) ->
                  Ext = objfile_extension(machine(Flags)),
                  ModuleFilename = to_list(Module) ++ Ext,
                  add_file(filename:join([ToDir, "ebin"]), AppDir, ModuleFilename, Acc)
          end, [], Modules),
    Files1 = add_dir_if(ToDir, ADir, "priv", Files0),
    Files2 = add_file(filename:join([ToDir, "ebin"]), AppDir,  to_list(Name) ++ ".app", Files1),
    add_flags_dir(ToDir, ADir, Flags, Files2).

add_file(Target, Source, Filename, Files) ->
    [{filename:join([Target, Filename]), filename:join([Source, Filename])}|Files].

add_dir_if(Target, Source, Dir, Files) ->
    FromD = filename:join(Source, Dir),
    case dirp(FromD) of
	true ->
	    add_file(Target, Source, Dir, Files);
	_ ->
	    Files
    end.

add_flags_dir(ToDir, ADir, Flags, Files) ->
    case get_flag(dirs,Flags) of
        {dirs,Dirs} ->
            lists:foldl(
              fun(Dir, Acc) ->
                      add_dir_if(ToDir, ADir, Dir, Acc)
              end, Files, Dirs);
        _ ->
            Files
    end.


to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L)                 -> L.


appDir(AppDir) ->
    case filename:basename(AppDir) of
	"ebin" -> filename:dirname(AppDir);
	_ -> AppDir
    end.

dirp(Dir) ->
    case file:read_file_info(Dir) of
	{ok, FileInfo} -> FileInfo#file_info.type == directory;
	_ ->              false
    end.

get_path(Flags) ->
    case get_flag(path,Flags) of
	{path,Path} when is_list(Path) -> Path;
	_                              -> []
    end.

%% Get a key-value tuple flag from a list.

get_flag(F,[{F,D}|_]) -> {F,D};
get_flag(F,[_|Fs])    -> get_flag(F,Fs);
get_flag(_,_)         -> false.

mk_path(Path0) ->
    Path1 = lists:map(fun to_list/1, Path0),
    systools_lib:get_path(Path1).

make_set([]) -> [];
make_set([""|T]) -> % Ignore empty items.
    make_set(T);
make_set([H|T]) ->
    [H | [ Y || Y<- make_set(T),
		Y =/= H]].

objfile_extension(false) ->
    code:objfile_extension();
objfile_extension(Machine) ->
    "." ++ atom_to_list(Machine).

machine(Flags) ->
    case get_flag(machine,Flags) of
	{machine, Machine} when is_atom(Machine) -> Machine;
	_                                        -> false
    end.
