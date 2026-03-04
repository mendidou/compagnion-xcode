process.on('uncaughtException', (err) => {
  console.error('[relay] FATAL:', err)
  process.exit(1)
})

const http = require('http')
const WebSocket = require('ws')

const port = parseInt(process.env.PORT, 10) || 8765
const rooms = {}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200)
    res.end('ok')
    return
  }
  res.writeHead(404)
  res.end()
})

const wss = new WebSocket.Server({ server })

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost')
  const roomId = url.searchParams.get('room')
  const role = url.searchParams.get('role')   // 'mac' or 'ios'

  if (!roomId || !role) {
    ws.close(1008, 'Missing room or role')
    return
  }

  if (!rooms[roomId]) rooms[roomId] = {}
  rooms[roomId][role] = ws
  console.log(`[relay] ${role} connected  room=${roomId.slice(0, 8)}…  peers=${Object.keys(rooms[roomId]).join(',')}`)

  ws.on('message', (data, isBinary) => {
    const partner = role === 'mac' ? rooms[roomId]?.ios : rooms[roomId]?.mac
    if (!isBinary) {
      const partnerRole = role === 'mac' ? 'ios' : 'mac'
      const ready = partner?.readyState
      console.log(`[relay] ${role}→${partnerRole}  text ${data.length}B  partner=${ready === 1 ? 'ready' : ready ?? 'missing'}`)
    }
    if (partner?.readyState === 1) {
      partner.send(data, { binary: isBinary })
    }
  })

  ws.on('close', () => {
    if (rooms[roomId]) {
      delete rooms[roomId][role]
      if (!rooms[roomId].mac && !rooms[roomId].ios) delete rooms[roomId]
    }
    console.log(`[relay] ${role} disconnected  room=${roomId.slice(0, 8)}…`)
  })

  ws.on('error', (err) => {
    console.error(`[relay] ${role} error  room=${roomId.slice(0, 8)}… :`, err.message)
  })
})

server.listen(port, () => {
  console.log(`[relay] WebSocket server listening on port ${port}`)
})
