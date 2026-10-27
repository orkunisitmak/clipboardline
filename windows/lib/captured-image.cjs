'use strict';
// One shared decision for every captured image arrival: the app's own
// screenshot, an image copied from another app, and a file landing in a
// watched folder must all be offered through the same flow.
const OPEN_MODES = Object.freeze(['crop', 'preview', 'shelf', 'off']);

function capturedImageEvent(settings, record) {
  if (!record || record.kind !== 'image') return null;
  const mode = OPEN_MODES.includes(settings?.capturedImageOpens) ? settings.capturedImageOpens : 'crop';
  if (mode === 'off') return null;
  // Recordings have no still to preview or crop; shelf mode only selects the item.
  if (mode === 'shelf' || record.recording) return { selectId: record.id, kind: 'image' };
  if (mode === 'preview') return { selectId: record.id, kind: 'image', preview: true };
  return { selectId: record.id, kind: 'image', preview: true, crop: true };
}

module.exports = { capturedImageEvent, OPEN_MODES };
