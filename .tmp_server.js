const http = require('http');
const fs = require('fs');
const path = require('path');
http.createServer((req, res) => {
  const file = path.join(__dirname, 'daria_report_render.html');
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(500); res.end('err'); return; }
    res.writeHead(200, {'Content-Type': 'text/html'});
    res.end(data);
  });
}).listen(8765, () => console.log('serving on 8765'));
