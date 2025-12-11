const puppeteer = require('./node_modules/puppeteer');
const http = require('http');
const fs = require('fs');

const server = http.createServer((req, res) => {
    const html = fs.readFileSync('/tmp/nav_test.html', 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
});

server.listen(8772, async () => {
    console.log('Server running on port 8772');
    
    const browser = await puppeteer.launch({ headless: 'new' });
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });
    
    page.on('console', msg => console.log('PAGE:', msg.text()));
    page.on('pageerror', err => console.log('ERROR:', err.message));
    
    await page.goto('http://localhost:8772', { waitUntil: 'networkidle0', timeout: 60000 });
    await new Promise(r => setTimeout(r, 5000));
    
    // Find a dependency (grey node) that is used by multiple projects
    const result = await page.evaluate(() => {
        // Find a dependency with multiple dependents
        const depNode = allNodes.find(n => {
            if (n.color !== '#6c757d') return false;
            const dependents = adjacencyMap[n.id]?.dependents || [];
            return dependents.length > 3;
        });
        if (depNode) {
            return { nodeId: depNode.id, dependents: adjacencyMap[depNode.id]?.dependents?.length };
        }
        return null;
    });
    
    console.log('Found dependency:', result);
    
    // Navigate to dependents view
    if (result) {
        await page.evaluate((nodeId) => {
            navigateToNode(nodeId, 'dependents');
        }, result.nodeId);
        
        await new Promise(r => setTimeout(r, 3000));
        
        // Take screenshot
        await page.screenshot({ path: '/tmp/dependents_view.png' });
        console.log('Dependents view screenshot saved');
        
        // Check breadcrumbs
        const breadcrumbText = await page.$eval('#breadcrumbs', el => el.textContent.trim());
        console.log('Breadcrumb:', breadcrumbText);
    }
    
    await browser.close();
    server.close();
});
