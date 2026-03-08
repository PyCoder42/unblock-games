/**
 * Google Apps Script — Unblock Games Remote Config Server
 *
 * Deploy as: Web app → "Anyone" can access
 *
 * Setup:
 *   1. Create a new Google Apps Script project at script.google.com
 *   2. Replace the default Code.gs content with this file
 *   3. Go to Project Settings → Script Properties and add:
 *      - secretKey = <your chosen passphrase>
 *      - config = {}
 *   4. Deploy → New deployment → Web app → "Anyone" → Deploy
 *   5. Copy the deployment URL (https://script.google.com/macros/s/.../exec)
 *
 * Reads are public (no key needed). Writes require the secret key.
 *
 * Endpoints (all via GET, JSONP):
 *   ?action=read&callback=cb
 *   ?action=write&key=SECRET&writeAction=updatePassword&password=NEW&callback=cb
 *   ?action=write&key=SECRET&writeAction=block&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=unblock&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=timeblock&game=GAME_ID&until=ISO_DATE&callback=cb
 *   ?action=write&key=SECRET&writeAction=addGame&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=fullSync&config=JSON_STRING&callback=cb
 */

function doGet(e) {
  var action = e.parameter.action || 'read';
  var callback = e.parameter.callback || 'callback';
  var props = PropertiesService.getScriptProperties();
  var config = JSON.parse(props.getProperty('config') || '{}');

  if (action === 'read') {
    return ContentService.createTextOutput(callback + '(' + JSON.stringify(config) + ')')
      .setMimeType(ContentService.MimeType.JAVASCRIPT);
  }

  if (action === 'write') {
    var key = e.parameter.key || '';
    var storedKey = props.getProperty('secretKey') || '';
    if (key !== storedKey) {
      return ContentService.createTextOutput(callback + '({"error":"unauthorized"})')
        .setMimeType(ContentService.MimeType.JAVASCRIPT);
    }

    var writeAction = e.parameter.writeAction || '';

    if (writeAction === 'updatePassword') {
      config.password = e.parameter.password || config.password;
    } else if (writeAction === 'block') {
      config.blocked = config.blocked || {};
      config.blocked[e.parameter.game] = true;
    } else if (writeAction === 'unblock') {
      if (config.blocked) delete config.blocked[e.parameter.game];
    } else if (writeAction === 'timeblock') {
      config.blocked = config.blocked || {};
      config.blocked[e.parameter.game] = e.parameter.until;
    } else if (writeAction === 'addGame') {
      config.games = config.games || [];
      if (config.games.indexOf(e.parameter.game) === -1) {
        config.games.push(e.parameter.game);
      }
    } else if (writeAction === 'fullSync') {
      config = JSON.parse(e.parameter.config || '{}');
    } else {
      return ContentService.createTextOutput(callback + '({"error":"unknown writeAction"})')
        .setMimeType(ContentService.MimeType.JAVASCRIPT);
    }

    props.setProperty('config', JSON.stringify(config));
    return ContentService.createTextOutput(callback + '({"success":true})')
      .setMimeType(ContentService.MimeType.JAVASCRIPT);
  }

  return ContentService.createTextOutput(callback + '({"error":"unknown action"})')
    .setMimeType(ContentService.MimeType.JAVASCRIPT);
}
