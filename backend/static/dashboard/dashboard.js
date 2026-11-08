document.addEventListener('DOMContentLoaded', () => {
  const adminKeyInput = document.getElementById('adminKey');
  const saveKeyBtn = document.getElementById('saveKeyBtn');
  const filterStatusSelect = document.getElementById('filterStatus');
  const filterReportTypeSelect = document.getElementById('filterReportType');
  const loadReportsBtn = document.getElementById('loadReportsBtn');
  const refreshViewBtn = document.getElementById('refreshViewBtn');
  const exportCsvBtn = document.getElementById('exportCsvBtn');
  const exportJsonBtn = document.getElementById('exportJsonBtn');
  const mapNotice = document.getElementById('mapNotice');

  // Restore saved key — never fall back to a default, the operator must paste one.
  adminKeyInput.value = localStorage.getItem('resilientsteps_admin_key') || '';

  saveKeyBtn.addEventListener('click', () => {
    if (!adminKey()) {
      alert('Enter your admin key before saving.');
      return;
    }
    localStorage.setItem('resilientsteps_admin_key', adminKey());
    alert('Admin key saved.');
    loadDashboardData();
  });

  function adminKey() {
    return adminKeyInput.value.trim();
  }

  function getHeaders() {
    return {
      'X-Admin-Key': adminKey(),
      'Content-Type': 'application/json'
    };
  }

  // Canonical codes (R-065) render as readable words ('poor_lighting' -> 'Poor lighting').
  function humanizeCategory(code) {
    const text = String(code || '');
    if (!text.includes('_')) return text;
    return text.split('_').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
  }

  // ===== Sidebar view switching (map first; sidebar switches views client-side) =====
  function switchView(name) {
    document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
    const target = document.getElementById('view-' + name);
    if (target) target.classList.add('active');
    document.querySelectorAll('.side-nav .nav-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.view === name);
    });
    if (name === 'map') showMapView();
  }

  document.querySelectorAll('[data-view]').forEach(el => {
    el.addEventListener('click', () => {
      switchView(el.dataset.view);
      const status = el.dataset.status;
      if (el.dataset.view === 'reports' && status !== undefined) {
        filterStatusSelect.value = status;
        loadReportsTable();
      }
    });
  });

  // ===== Module breakdown rows (sidebar snapshot) =====
  document.querySelectorAll('[data-type]').forEach(el => {
    el.addEventListener('click', () => {
      filterReportTypeSelect.value = el.dataset.type;
      switchView('reports');
      loadReportsTable();
    });
  });

  // ===== City summary -> sidebar snapshot + breakdown =====
  async function loadDashboardSummary() {
    try {
      const res = await fetch('/dashboard/summary', { headers: getHeaders() });
      if (!res.ok) return;
      const data = await res.json();

      document.getElementById('statTotal').textContent = data.total_reports || 0;
      document.getElementById('statPending').textContent = data.pending_count || 0;
      document.getElementById('statVerified').textContent = data.verified_count || 0;
      document.getElementById('statRejected').textContent = data.rejected_count || 0;
      document.getElementById('sideStatTotal').textContent = data.total_reports || 0;
      document.getElementById('sideStatPending').textContent = data.pending_count || 0;
      document.getElementById('sideStatVerified').textContent = data.verified_count || 0;
      document.getElementById('sideStatRejected').textContent = data.rejected_count || 0;

      const byType = data.by_type || {};
      document.getElementById('cntSafety').textContent = byType.safety || 0;
      document.getElementById('cntInfra').textContent = byType.infrastructure || 0;
      document.getElementById('cntWaste').textContent = byType.waste || 0;
    } catch (e) {
      console.warn('Failed to load city summary:', e);
    }
  }

  // ===== Map pins: every complaint, every status =====
  // The existing /dashboard/export?format=json endpoint already returns all
  // reports with coordinates, so no backend change is needed.
  async function loadComplaintPins() {
    if (!adminKey()) {
      mapNotice.style.display = 'block';
      clearMapPins();
      return;
    }
    try {
      const res = await fetch('/dashboard/export?format=json', { headers: getHeaders() });
      if (!res.ok) {
        mapNotice.textContent = `Could not load complaint pins (${res.status}). Check your admin key.`;
        mapNotice.style.display = 'block';
        return;
      }
      const reports = await res.json();
      // Same feed powers the map pins AND the filtered exports (S-116):
      // one server call, client-side status/type filtering, empty-set abort.
      allReportsCache = reports || [];
      mapNotice.style.display = 'none';
      renderComplaintPins(reports || []);
    } catch (e) {
      mapNotice.textContent = 'Error loading complaint pins.';
      mapNotice.style.display = 'block';
      console.warn('Pin load failed:', e);
    }
  }

  // ===== Data-driven exports (S-116: client-side filtered from the fetched
  // all-reports feed; refused on empty set; backend contract untouched) =====
  let allReportsCache = [];

  function csvEscape(value) {
    const s = value == null ? '' : String(value);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  function toCsv(rows) {
    const fields = [
      'id', 'user_hash', 'category', 'description', 'latitude', 'longitude',
      'status', 'confidence', 'severity', 'report_type', 'submitted_at', 'moderated_at'
    ];
    const head = fields.join(',');
    const body = rows.map(r => fields.map(f => csvEscape(r[f])).join(','));
    return [head].concat(body).join('\n');
  }

  async function exportReports(format) {
    if (!adminKey()) {
      alert('Paste your admin key in the sidebar first.');
      return;
    }
    if (allReportsCache.length === 0) {
      alert('No data present — no reports have been logged yet, so there is nothing to export.');
      return;
    }

    const status = filterStatusSelect.value;
    const type = filterReportTypeSelect.value;
    const filtered = allReportsCache.filter(r =>
      (!status || (r.status || 'pending') === status) &&
      (!type || (r.report_type || 'safety') === type)
    );

    if (filtered.length === 0) {
      alert(
        `No reports match the current filters (module: ${type || 'all'}, status: ${status || 'all'}) — nothing to export.`
      );
      return;
    }

    const suffix = [type, status].filter(Boolean).join('_');
    const base = 'resilientsteps_reports_export' + (suffix ? `_${suffix}` : '');
    let content;
    if (format === 'csv') {
      content = toCsv(filtered);
    } else {
      content = JSON.stringify(filtered, null, 2);
    }
    const blob = new Blob([content], { type: format === 'csv' ? 'text/csv' : 'application/json' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `${base}.${format}`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  exportCsvBtn.addEventListener('click', () => exportReports('csv'));
  exportJsonBtn.addEventListener('click', () => exportReports('json'));

  async function refreshWardView() {
    try {
      const res = await fetch('/dashboard/refresh-summary', {
        method: 'POST',
        headers: getHeaders()
      });
      if (res.ok) {
        alert('Ward summary refreshed!');
        loadDashboardData();
      } else {
        alert(`Refresh failed (${res.status}). Check your admin key.`);
      }
    } catch (e) {
      alert('Error refreshing view.');
    }
  }

  refreshViewBtn.addEventListener('click', refreshWardView);

  // ===== Incident management table =====
  async function fetchReportsForStatus(status, reportType) {
    let url = `/admin/reports?status=${encodeURIComponent(status)}`;
    if (reportType) {
      url += `&report_type=${encodeURIComponent(reportType)}`;
    }
    const res = await fetch(url, { headers: getHeaders() });
    if (!res.ok) {
      throw new Error(`status ${status} failed (${res.status})`);
    }
    const data = await res.json();
    return data.reports || [];
  }

  async function loadReportsTable() {
    const status = filterStatusSelect.value;
    const reportType = filterReportTypeSelect.value;
    const tbody = document.getElementById('reportsTableBody');

    if (!adminKey()) {
      tbody.innerHTML =
        '<tr><td colspan="9" class="text-center text-danger">Paste your admin key in the sidebar to load reports.</td></tr>';
      return;
    }

    tbody.innerHTML = '<tr><td colspan="9" class="text-center">Loading reports...</td></tr>';

    try {
      // "All" merges one fetch per status; /admin/reports contract untouched.
      const statuses = status ? [status] : ['pending', 'verified', 'rejected'];
      const chunks = await Promise.all(
        statuses.map(s => fetchReportsForStatus(s, reportType).catch(() => []))
      );

      const reports = chunks
        .flat()
        .sort((a, b) => new Date(b.submitted_at) - new Date(a.submitted_at));

      if (!reports.length) {
        tbody.innerHTML = `<tr><td colspan="9" class="text-center">No ${status || 'matching'} reports found.</td></tr>`;
        return;
      }

      tbody.innerHTML = reports.map(r => `
        <tr>
          <td>${r.id}</td>
          <td><span class="badge badge-${escapeHtml(r.report_type || 'safety')}">${escapeHtml(r.report_type || 'safety')}</span></td>
          <td><strong>${escapeHtml(humanizeCategory(r.category || ''))}</strong>${
            r.ai && r.ai.category
              ? `<div class="text-muted" style="font-size:.72em" title="Nugen suggestion (${escapeHtml(String(r.ai.reason || ''))})">AI: ${escapeHtml(humanizeCategory(r.ai.category))} (conf ${Number(r.ai.confidence ?? 0).toFixed(2)}, sev ${r.ai.severity ?? '-'}${r.ai.severity_label ? ' ' + escapeHtml(String(r.ai.severity_label)) : ''})</div>`
              : ''
          }</td>
          <td>${escapeHtml(r.description || 'N/A')}</td>
          <td class="coords-cell" data-lat="${r.latitude ?? ''}" data-lon="${r.longitude ?? ''}">
            ${r.latitude ? r.latitude.toFixed(4) : ''}, ${r.longitude ? r.longitude.toFixed(4) : ''}
          </td>
          <td>${r.severity || 3}</td>
          <td>${r.submitted_at ? new Date(r.submitted_at).toLocaleString() : ''}</td>
          <td><span class="badge badge-status-${escapeHtml(r.status || 'pending')}">${escapeHtml(r.status || 'pending')}</span></td>
          <td>
            ${r.status === 'pending' ? `
              <button class="action-btn-sm btn-verify" onclick="moderateReport(${r.id}, 'verify')">Verify</button>
              <button class="action-btn-sm btn-reject" onclick="moderateReport(${r.id}, 'reject')">Reject</button>
            ` : '—'}
          </td>
        </tr>
      `).join('');
    } catch (e) {
      tbody.innerHTML = `<tr><td colspan="9" class="text-center text-danger">Error fetching data</td></tr>`;
    }
  }

  window.moderateReport = async function(id, action) {
    if (!confirm(`Are you sure you want to ${action} report #${id}?`)) return;

    try {
      const res = await fetch(`/admin/reports/${id}/${action}`, {
        method: 'POST',
        headers: getHeaders()
      });
      if (res.ok) {
        loadDashboardData();
      } else {
        alert(`Action failed: ${res.statusText}`);
      }
    } catch (e) {
      alert(`Error performing action: ${e}`);
    }
  };

  function loadDashboardData() {
    loadDashboardSummary();
    loadReportsTable();
    loadComplaintPins();
  }

  loadReportsBtn.addEventListener('click', loadReportsTable);

  // Clicking a report's coordinates in the table jumps to that area on the map.
  document.getElementById('reportsTableBody').addEventListener('click', (e) => {
    const cell = e.target.closest('.coords-cell');
    if (!cell) return;
    const lat = parseFloat(cell.dataset.lat);
    const lon = parseFloat(cell.dataset.lon);
    if (isNaN(lat) || isNaN(lon)) return;
    const row = cell.closest('tr');
    const cols = row.querySelectorAll('td');
    const popupHtml = panePopupHtml(cols);
    switchView('map');
    focusComplaintArea(lat, lon, popupHtml);
  });

  function panePopupHtml(cols) {
    return `
      <div class="pin-popup">
        <strong>${cols[2] ? cols[2].textContent.trim() : 'Incident'}</strong><br/>
        Type: ${escapeHtml(cols[1] ? cols[1].textContent.trim() : '')}<br/>
        Severity: ${escapeHtml(cols[5] ? cols[5].textContent.trim() : '')}<br/>
        Status: ${escapeHtml(cols[7] ? cols[7].textContent.trim() : '')}<br/>
        <small>${escapeHtml(cols[3] ? cols[3].textContent.trim() : '')}</small>
      </div>
    `;
  }

  // Initial Load — map is the first view, pins load right away.
  initDashboardMap('map');
  document.getElementById('view-map').classList.add('active');
  loadDashboardData();
});
