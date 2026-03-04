export interface Env {
  ROOMS: DurableObjectNamespace
}

// Each room is a Durable Object that bridges two WebSocket connections.
// One connection is the Mac (role=mac), the other is the iOS device (role=ios).
// The relay is protocol-agnostic: it forwards binary and text frames between peers.
export class Room implements DurableObject {
  private sockets = new Map<string, WebSocket>()

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected WebSocket', { status: 426 })
    }

    const role = new URL(request.url).searchParams.get('role')
    if (!role) return new Response('Missing role', { status: 400 })

    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]

    // Close any existing connection for this role before replacing
    const existing = this.sockets.get(role)
    if (existing) {
      try { existing.close(1001, 'Replaced by new connection') } catch {}
    }

    this.sockets.set(role, server)
    server.accept()

    const partner = role === 'mac' ? 'ios' : 'mac'

    server.addEventListener('message', (event) => {
      const peer = this.sockets.get(partner)
      if (peer) {
        try { peer.send(event.data) } catch {}
      }
    })

    server.addEventListener('close', () => {
      this.sockets.delete(role)
    })

    server.addEventListener('error', () => {
      this.sockets.delete(role)
    })

    return new Response(null, { status: 101, webSocket: client })
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const roomId = url.searchParams.get('room')
    if (!roomId) return new Response('Missing room', { status: 400 })

    const id = env.ROOMS.idFromName(roomId)
    const stub = env.ROOMS.get(id)
    return stub.fetch(request)
  },
}
