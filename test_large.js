const puppeteer = require('./node_modules/puppeteer');
const http = require('http');
const fs = require('fs');

const server = http.createServer((req, res) => {
    const html = fs.readFileSync('/tmp/large_test.html', 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
});

server.listen(8766, async () => {
    console.log('Server running on port 8766');
    
    const browser = await puppeteer.launch({ headless: 'new' });
    const page = await browser.newPage();
    
    page.on('console', msg => console.log('PAGE LOG:', msg.text()));
    page.on('pageerror', err => console.log('PAGE ERROR:', err.message));
    
    await page.goto('http://localhost:8766', { waitUntil: 'networkidle0', timeout: 60000 });
    
    // Wait longer for large graph stabilization
    await new Promise(r => setTimeout(r, 5000));
    
    const result = await page.evaluate(() => {
        const canvas = document.querySelector('#graph canvas');
        return {
            hasCanvas: !!canvas,
            canvasWidth: canvas ? canvas.width : 0,
            canvasHeight: canvas ? canvas.height : 0,
            visibleNodes: document.querySelectorAll('#graph canvas').length
        };
    });
    
    console.log('Result:', JSON.stringify(result, null, 2));
    
    // Take a screenshot
    await page.screenshot({ path: '/tmp/graph_screenshot.png', fullPage: false });
    console.log('Screenshot saved to /tmp/graph_screenshot.png');
    
    await browser.close();
    server.close();
});
