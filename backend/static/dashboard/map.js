let dashboardMap = null;
let pinLayerGroup = null;

// Report fields are user-submitted, so escape them before they reach any HTML
// sink. dashboard.js (loaded after this file) reuses this single definition.
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  }[ch]));
}

function initDashboardMap(containerId) {
  if (dashboardMap) return dashboardMap;

  // Center on Pune
  dashboardMap = L.map(containerId).setView([18.5204, 73.8567], 12);

  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© OpenStreetMap contributors'
  }).addTo(dashboardMap);

  pinLayerGroup = L.layerGroup().addTo(dashboardMap);

  // The map lives in a hidden section until the map view is opened; Leaflet
  // needs a nudge to size tiles correctly once the container becomes visible.
  setTimeout(() => dashboardMap.invalidateSize(), 250);

  return dashboardMap;
}

function showMapView() {
  if (dashboardMap) {
    setTimeout(() => dashboardMap.invalidateSize(), 100);
  }
}

function clearMapPins() {
  if (pinLayerGroup) {
    pinLayerGroup.clearLayers();
  }
}

// Red pin emoji marker for each complaint coordinate.
function makePinIcon() {
  return L.divIcon({
    className: 'pin-wrapper',
    html: '<span class="pin-emoji">📍</span>',
    iconSize: [28, 28],
    iconAnchor: [14, 26],
    popupAnchor: [0, -26]
  });
}

function pinPopupHtml(report) {
  const lat = parseFloat(report.latitude ?? report.lat);
  const lon = parseFloat(report.longitude ?? report.lon);
  const status = String(report.status || 'pending').toLowerCase();
  const actions = status === 'pending'
    ? `<div class="popup-actions">
         <button class="popup-btn popup-verify" onclick="moderateReport(${parseInt(report.id, 10)}, 'verify')">Verify</button>
         <button class="popup-btn popup-reject" onclick="moderateReport(${parseInt(report.id, 10)}, 'reject')">Reject</button>
       </div>`
    : '';
  return `
    <div class="pin-popup">
      <strong>${escapeHtml(report.category || 'Incident')}</strong><br/>
      Type: ${escapeHtml(report.report_type || 'safety')}<br/>
      Severity: ${escapeHtml(report.severity ?? 3)}<br/>
      Status: ${escapeHtml(report.status || 'pending')}<br/>
      <small>${escapeHtml(report.description || '')}</small><br/>
      <small>Coords: ${isNaN(lat) ? 'N/A' : lat.toFixed(5)}, ${isNaN(lon) ? 'N/A' : lon.toFixed(5)}</small>
      ${actions}
    </div>
  `;
}

// Renders a red pin for every complaint, across every status. Clicking a pin
// flies the map into that area and opens its details ("work through the rest").
function renderComplaintPins(reports) {
  clearMapPins();
  if (!reports || !reports.length) return;

  const bounds = L.latLngBounds();

  reports.forEach(r => {
    const lat = parseFloat(r.latitude ?? r.lat);
    const lon = parseFloat(r.longitude ?? r.lon);
    if (isNaN(lat) || isNaN(lon)) return;

    const marker = L.marker([lat, lon], { icon: makePinIcon(), title: r.category || 'Complaint' });
    marker.bindPopup(pinPopupHtml(r));
    marker.on('click', () => {
      dashboardMap.flyTo([lat, lon], 16, { duration: 0.8 });
    });
    pinLayerGroup.addLayer(marker);
    bounds.extend([lat, lon]);
  });

  if (bounds.isValid()) {
    dashboardMap.fitBounds(bounds, { padding: [40, 40], maxZoom: 15 });
  }
}

// Zoom into a single area and open its details popup.
function focusComplaintArea(lat, lon, popupHtml) {
  if (!dashboardMap) return;
  dashboardMap.flyTo([lat, lon], 16, { duration: 0.8 });
  if (popupHtml) {
    L.popup({ maxWidth: 320 }).setLatLng([lat, lon]).setContent(popupHtml).openOn(dashboardMap);
  }
}
