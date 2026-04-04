//// kirari 진입점 — CLI 실행 및 에러 처리

import argv
import kirari/cli
import kirari/platform

pub fn main() -> Nil {
  case cli.run(argv.load().arguments) {
    Ok(Nil) -> Nil
    Error(err) -> {
      cli.print_error(err)
      platform.halt(1)
    }
  }
}
