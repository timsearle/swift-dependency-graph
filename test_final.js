const puppeteer = require('./node_modules/puppeteer');
const http = require('http');
const fs = require('fs');

const server = http.createServer((req, res) => {
    const html = fs.readFileSync('/tmp/angle_test.html', 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
});

server.listen(8768, async () => {
    console.log('Server running on port 8768');
    
    const browser = await puppeteer.launch({ headless: 'new' });
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });
    
    page.on('console', msg => console.log('PAGE LOG:', msg.text()));
    page.on('pageerror', err => console.log('PAGE ERROR:', err.message));
    
    await page.goto('http://localhost:8768', { waitUntil: 'networkidle0', timeout: 60000 });
    
    // Wait for stabilization, angle adjustment, and fit
    await new Promise(r => setTimeout(r, 10000));
    
    const result = await page.evaluate(() => {
        const canvas = document.querySelector('#graph canvas');
        return {
            hasCanvas: !!canvas,
            canvasWidth: canvas ? canvas.width : 0,
            canvasHeight: canvas ? canvas.height : 0
        };
    });
    
    console.log('Result:', JSON.stringify(result, null, 2));
    
    await page.screenshot({ path: '/tmp/final_screenshot.png', fullPage: false });
    console.log('Screenshot saved to /tmp/final_screenshot.png');
    
    await browser.close();
    server.close();
});
