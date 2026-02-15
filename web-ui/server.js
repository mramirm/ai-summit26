const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const app = express();
const PORT = 3000;

// Serve static files from 'public' directory
app.use(express.static('public'));

app.get('/api/config', (req, res) => {
  res.json({
    bucketName: process.env.BUCKET_NAME || ''
  });
});

// Proxy API requests to vLLM
app.use('/v1', createProxyMiddleware({
  target: 'http://localhost:8080/v1',
  changeOrigin: true,
  logger: console,
  onProxyReq: (proxyReq, req, res) => {
    console.log(`[Proxy] ${req.method} ${req.url} -> http://localhost:8080/v1${req.url}`);
  },
  onError: (err, req, res) => {
    console.error('Proxy Error:', err);
    res.status(500).send('Proxy Error');
  }
}));

app.listen(PORT, () => {
  console.log(`
    🚀 UI Server running at: http://localhost:${PORT}
    ⚡️ Proxying /v1 -> http://localhost:8080/v1
    `);
});
