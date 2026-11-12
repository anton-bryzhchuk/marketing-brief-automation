'use strict';

const { createServer } = require('node:http');

const fixtures = {
  en: {
    seo_title: 'A practical guide for your next campaign',
    meta_description: 'Plan a focused campaign with clear audience goals, a content outline and a review checklist.',
    outline: ['Define the audience', 'Set a campaign goal', 'Choose channels', 'Draft the message', 'Review before launch'],
    linkedin_post: 'Planning a new campaign? Start with your audience, pick one clear goal and give the draft an editorial review before launch.',
    keywords: ['campaign planning', 'audience research', 'content outline', 'marketing goals', 'editorial review'],
  },
  de: {
    seo_title: 'Ein Leitfaden für Ihre nächste Kampagne',
    meta_description: 'Planen Sie eine Kampagne mit klaren Zielen, einer Inhaltsstruktur und einer Checkliste für die Freigabe.',
    outline: ['Zielgruppe bestimmen', 'Kampagnenziel festlegen', 'Kanäle auswählen', 'Botschaft entwerfen', 'Entwurf prüfen'],
    linkedin_post: 'Planen Sie eine neue Kampagne? Beginnen Sie mit der Zielgruppe, wählen Sie ein klares Ziel und lassen Sie den Entwurf redaktionell prüfen.',
    keywords: ['Kampagnenplanung', 'Zielgruppenanalyse', 'Inhaltsstruktur', 'Marketingziele', 'redaktionelle Prüfung'],
  },
};

function respond(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify(body));
}

createServer(async (request, response) => {
  if (request.method === 'GET' && request.url === '/healthz') {
    return respond(response, 200, { status: 'ok' });
  }
  if (request.method !== 'POST' || request.url !== '/v1/messages') {
    return respond(response, 404, { error: 'Not found' });
  }

  let payload = '';
  try {
    for await (const chunk of request) {
      payload += chunk;
      if (payload.length > 16_384) return respond(response, 413, { error: 'Body too large' });
    }

    const { messages } = JSON.parse(payload);
    const { topic, language } = JSON.parse(messages[0].content);
    const fixture = fixtures[language];
    if (typeof topic !== 'string' || !Object.hasOwn(fixtures, language)) {
      return respond(response, 400, { error: 'Invalid mock request' });
    }

    const forcedError = topic.includes('FORCE_ERROR');
    console.log(JSON.stringify({
      run_id: request.headers['x-demo-run-id'],
      correction: messages.length > 1,
      status: forcedError ? 500 : 200,
    }));
    if (forcedError) {
      return respond(response, 500, { type: 'error', error: { type: 'api_error', message: 'Simulated outage' } });
    }

    const text = topic.includes('FORCE_INVALID') ? '{ deliberately invalid JSON' : JSON.stringify(fixture);
    return respond(response, 200, { type: 'message', role: 'assistant', stop_reason: 'end_turn', content: [{ type: 'text', text }] });
  } catch {
    return respond(response, 400, { error: 'Invalid mock request' });
  }
}).listen(3000, '0.0.0.0');
