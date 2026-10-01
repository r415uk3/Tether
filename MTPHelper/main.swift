import Foundation
import CLibMTP
import MTPKit

LIBMTP_Init()
let listener = NSXPCListener.service()
listener.resume() // never returns
