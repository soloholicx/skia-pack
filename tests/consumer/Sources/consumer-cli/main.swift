import Foundation
import SkiaPackConsumer

let rc = skia_pack_consumer_check()
if rc != 0 { print("consumer FAIL: check returned \(rc)") }
exit(rc)
