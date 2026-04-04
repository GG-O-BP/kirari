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
    exec_command/1,
    app_version/0,
    get_platform_os/0,
    get_platform_arch/0,
    get_file_mtime/1,
    make_symlink/2,
    chmod_executable/1,
    verify_ecdsa_signature/3,
    get_current_timestamp/0,
    get_env/1,
    uuid_v4/0
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

%% 포트 옵션 — Windows에서 hide로 CMD 창 억제
port_opts() ->
    Base = [stream, exit_status, binary, stderr_to_stdout],
    case os:type() of
        {win32, _} -> [hide | Base];
        _ -> Base
    end.

%% 셸 명령어 실행 — 종료 코드와 출력 반환
run_command(Cmd) when is_binary(Cmd) ->
    CmdStr = binary_to_list(Cmd),
    Port = open_port({spawn, CmdStr}, port_opts()),
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

%% 셸 명령어 실행 — stdout/stderr를 실시간 스트리밍, 종료 코드 반환
exec_command(Cmd) when is_binary(Cmd) ->
    CmdStr = binary_to_list(Cmd),
    Port = open_port({spawn, CmdStr}, port_opts()),
    stream_port(Port).

stream_port(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            stream_port(Port);
        {Port, {exit_status, Code}} ->
            Code
    end.

%% 플랫폼 OS 감지
get_platform_os() ->
    case os:type() of
        {win32, _} -> <<"win32">>;
        {unix, darwin} -> <<"darwin">>;
        {unix, linux} -> <<"linux">>;
        {unix, freebsd} -> <<"freebsd">>;
        {unix, Other} -> atom_to_binary(Other, utf8);
        _ -> <<"unknown">>
    end.

%% 플랫폼 아키텍처 감지
get_platform_arch() ->
    Arch = erlang:system_info(system_architecture),
    case Arch of
        "x86_64" ++ _ -> <<"x64">>;
        "aarch64" ++ _ -> <<"arm64">>;
        "arm" ++ _ -> <<"arm">>;
        "i686" ++ _ -> <<"ia32">>;
        "i386" ++ _ -> <<"ia32">>;
        _ -> list_to_binary(Arch)
    end.

%% 파일 수정 시각 (Unix 초)
get_file_mtime(Path) when is_binary(Path) ->
    case filelib:last_modified(binary_to_list(Path)) of
        0 -> {error, <<"not found">>};
        DateTime ->
            Seconds = calendar:datetime_to_gregorian_seconds(DateTime)
                    - calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
            {ok, Seconds}
    end.

%% 심볼릭 링크 생성
make_symlink(Target, Link) when is_binary(Target), is_binary(Link) ->
    case file:make_symlink(binary_to_list(Target), binary_to_list(Link)) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% 실행 권한 설정 (Unix: 755)
chmod_executable(Path) when is_binary(Path) ->
    case file:change_mode(binary_to_list(Path), 8#755) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% ECDSA 서명 검증 (npm Sigstore용)
verify_ecdsa_signature(Data, SignatureB64, PublicKeyPem) when
    is_binary(Data), is_binary(SignatureB64), is_binary(PublicKeyPem) ->
    try
        Sig = base64:decode(SignatureB64),
        [PemEntry | _] = public_key:pem_decode(PublicKeyPem),
        PubKey = public_key:pem_entry_decode(PemEntry),
        case public_key:verify(Data, sha256, Sig, PubKey) of
            true -> {ok, nil};
            false -> {error, <<"signature mismatch">>}
        end
    catch
        _:Reason -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% 현재 시각 RFC 3339 형식
get_current_timestamp() ->
    {{Y,Mo,D},{H,Mi,S}} = calendar:universal_time(),
    list_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
                                 [Y,Mo,D,H,Mi,S])).

%% 환경변수 조회
get_env(Key) when is_binary(Key) ->
    case os:getenv(binary_to_list(Key)) of
        false -> {error, <<"not set">>};
        Val -> {ok, list_to_binary(Val)}
    end.

%% UUID v4 생성 (RFC 4122)
uuid_v4() ->
    <<A:32, B:16, _:4, C:12, _:2, D:62>> = crypto:strong_rand_bytes(16),
    list_to_binary(io_lib:format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~1.16.0b~15.16.0b",
        [A, B, C, 8 bor (D bsr 60), D band 16#0FFFFFFFFFFFFFFF])).
