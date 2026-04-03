-module(kirari_ffi).
-export([
    extract_tar/2,
    extract_tar_uncompressed/2,
    make_hardlink/2,
    atomic_rename/2,
    get_home_dir/0,
    halt/1,
    make_temp_dir/1,
    run_command/1,
    app_version/0
]).

%% tar/tgz 압축 해제
extract_tar(Data, Dest) when is_binary(Data), is_binary(Dest) ->
    DestStr = binary_to_list(Dest),
    case erl_tar:extract({binary, Data}, [compressed, {cwd, DestStr}]) of
        ok -> {ok, nil};
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(lists:flatten(io_lib:format("~p", [Reason])))}
    end.

%% 비압축 tar 해제 (Hex 외부 tarball용)
extract_tar_uncompressed(Data, Dest) when is_binary(Data), is_binary(Dest) ->
    DestStr = binary_to_list(Dest),
    case erl_tar:extract({binary, Data}, [{cwd, DestStr}]) of
        ok -> {ok, nil};
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(lists:flatten(io_lib:format("~p", [Reason])))}
    end.

%% 하드링크 생성
make_hardlink(Src, Dst) when is_binary(Src), is_binary(Dst) ->
    case file:make_link(binary_to_list(Src), binary_to_list(Dst)) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% 원자적 이름 변경
atomic_rename(Src, Dst) when is_binary(Src), is_binary(Dst) ->
    case file:rename(binary_to_list(Src), binary_to_list(Dst)) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% 홈 디렉토리
get_home_dir() ->
    case os:getenv("HOME") of
        false ->
            %% Windows fallback
            case os:getenv("USERPROFILE") of
                false -> {error, <<"HOME not set">>};
                Path -> {ok, list_to_binary(Path)}
            end;
        Path -> {ok, list_to_binary(Path)}
    end.

%% 프로세스 종료
halt(Code) when is_integer(Code) ->
    erlang:halt(Code).

%% 임시 디렉토리 생성 (VM 재시작 시 unique_integer 충돌 방지)
make_temp_dir(Base) when is_binary(Base) ->
    Rand = integer_to_list(erlang:system_time(microsecond)) ++ "-" ++
           integer_to_list(erlang:unique_integer([positive])),
    Dir = binary_to_list(Base) ++ "/tmp-" ++ Rand,
    case file:make_dir(Dir) of
        ok -> {ok, list_to_binary(Dir)};
        {error, eexist} ->
            %% 이전 실행의 잔여 디렉토리 — 삭제 후 재생성
            del_dir_recursive(Dir),
            case file:make_dir(Dir) of
                ok -> {ok, list_to_binary(Dir)};
                {error, Reason2} -> {error, atom_to_binary(Reason2, utf8)}
            end;
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

del_dir_recursive(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(fun(F) ->
                Path = filename:join(Dir, F),
                case filelib:is_dir(Path) of
                    true -> del_dir_recursive(Path);
                    false -> file:delete(Path)
                end
            end, Files),
            file:del_dir(Dir);
        {error, _} -> ok
    end.

%% 애플리케이션 버전 — .app 메타데이터에서 읽기
app_version() ->
    _ = application:load(kirari),
    case application:get_key(kirari, vsn) of
        {ok, Vsn} -> {ok, list_to_binary(Vsn)};
        undefined -> {error, nil}
    end.

%% 셸 명령어 실행 — 종료 코드와 출력 반환
run_command(Cmd) when is_binary(Cmd) ->
    CmdStr = binary_to_list(Cmd),
    Port = open_port({spawn, CmdStr}, [stream, exit_status, binary, stderr_to_stdout]),
    collect_port(Port, <<>>).

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Code}} ->
            {error, {Code, Acc}}
    end.
