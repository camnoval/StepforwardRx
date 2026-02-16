// ═══════════════════════════════════════════════════════
// StepForward Rx — Researcher Dashboard
// ═══════════════════════════════════════════════════════

const SB_URL  = 'https://tcagznodtcvlnhharmgj.supabase.co';
const SB_KEY  = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU';

const sb = window.supabase.createClient(SB_URL, SB_KEY);

// ─── State ──────────────────────────────────────────
let session          = null;
let researcher       = null;
let pharmacyMap      = {};
let participantsList = [];
let currentParticipant  = null;
let currentMetrics      = [];
let currentSideEffects  = [];
let currentMedications  = [];
let chartInstances      = {};

// ─── Metric definitions ─────────────────────────────
const METRICS = [
    { key: 'walking_speed',        label: 'Walking Speed',        unit: 'm/s', color: '#667eea', worsens: 'decrease' },
    { key: 'walking_step_length',  label: 'Step Length',           unit: 'm',   color: '#38a169', worsens: 'decrease' },
    { key: 'walking_asymmetry',    label: 'Walking Asymmetry',    unit: '%',   color: '#d69e2e', worsens: 'increase' },
    { key: 'double_support_time',  label: 'Double Support Time',  unit: '%',   color: '#e53e3e', worsens: 'increase' },
    { key: 'walking_steadiness',   label: 'Walking Steadiness',   unit: '',    color: '#805ad5', worsens: 'decrease' },
];

// ═════════════════════════════════════════════════════
// AUTH
// ═════════════════════════════════════════════════════

function showError(msg) {
    const el = document.getElementById('authError');
    el.textContent = msg;
    el.style.display = 'block';
    document.getElementById('authSuccess').style.display = 'none';
}

function showSuccess(msg) {
    const el = document.getElementById('authSuccess');
    el.textContent = msg;
    el.style.display = 'block';
    document.getElementById('authError').style.display = 'none';
}

function clearMessages() {
    document.getElementById('authError').style.display = 'none';
    document.getElementById('authSuccess').style.display = 'none';
}

function showLogin() {
    clearMessages();
    document.getElementById('loginForm').style.display = 'block';
    document.getElementById('signupForm').style.display = 'none';
}

function showSignup() {
    clearMessages();
    document.getElementById('loginForm').style.display = 'none';
    document.getElementById('signupForm').style.display = 'block';
    loadPharmacyDropdown();
}

async function loadPharmacyDropdown() {
    const sel = document.getElementById('signupPharmacy');
    sel.innerHTML = '<option value="" disabled selected>Loading…</option>';

    const { data, error } = await sb.from('pharmacies').select('*').order('name');

    if (error || !data || data.length === 0) {
        sel.innerHTML = '<option value="" disabled selected>No pharmacies found</option>';
        return;
    }

    sel.innerHTML = '<option value="" disabled selected>Select a pharmacy…</option>' +
        data.map(p => {
            const loc = [p.city, p.state].filter(Boolean).join(', ');
            return `<option value="${p.id}">${p.name}${loc ? ' — ' + loc : ''}</option>`;
        }).join('');
}

function setAuthLoading(btn, loading, defaultText) {
    const textEl    = btn.querySelector('.btn-text');
    const spinnerEl = btn.querySelector('.btn-spinner');
    btn.disabled           = loading;
    textEl.textContent     = loading ? '' : defaultText;
    textEl.style.display   = loading ? 'none' : 'inline';
    spinnerEl.style.display = loading ? 'inline-block' : 'none';
}

// Enter key support
document.addEventListener('keydown', function(e) {
    if (e.key !== 'Enter') return;
    if (document.getElementById('loginForm').style.display !== 'none' &&
        document.getElementById('authScreen').style.display !== 'none') {
        handleLogin();
    } else if (document.getElementById('signupForm').style.display !== 'none' &&
               document.getElementById('authScreen').style.display !== 'none') {
        handleSignup();
    }
});

async function handleLogin() {
    clearMessages();
    const email = document.getElementById('loginEmail').value.trim();
    const pw    = document.getElementById('loginPassword').value;
    if (!email || !pw) { showError('Please fill in all fields.'); return; }

    const btn = document.getElementById('loginBtn');
    setAuthLoading(btn, true, 'Sign In');

    const { data, error } = await sb.auth.signInWithPassword({ email, password: pw });

    if (error) {
        showError(error.message);
        setAuthLoading(btn, false, 'Sign In');
        return;
    }

    session = data.session;
    showLoadingOverlay();
    await loadDashboard();
    setAuthLoading(btn, false, 'Sign In');
}

async function handleSignup() {
    clearMessages();
    const name    = document.getElementById('signupName').value.trim();
    const email   = document.getElementById('signupEmail').value.trim();
    const pw      = document.getElementById('signupPassword').value;
    const pharmId = document.getElementById('signupPharmacy').value;

    if (!name || !email || !pw || !pharmId) {
        showError('Please fill in all fields.');
        return;
    }
    if (pw.length < 6) {
        showError('Password must be at least 6 characters.');
        return;
    }

    const btn = document.getElementById('signupBtn');
    setAuthLoading(btn, true, 'Create Account');

    // 1) Create auth account
    const { data: authData, error: authErr } = await sb.auth.signUp({ email, password: pw });
    if (authErr) {
        showError(authErr.message);
        setAuthLoading(btn, false, 'Create Account');
        return;
    }

    const userId = authData.user?.id;
    if (!userId) {
        showError('Signup failed — no user ID returned.');
        setAuthLoading(btn, false, 'Create Account');
        return;
    }

    if (authData.session) session = authData.session;

    // 2) Insert researcher record
    const { error: resErr } = await sb.from('researchers').insert({ id: userId, email, name });
    if (resErr) {
        showError('Account created but failed to save researcher profile: ' + resErr.message);
        setAuthLoading(btn, false, 'Create Account');
        return;
    }

    // 3) Link to pharmacy
    const { error: linkErr } = await sb.from('researcher_pharmacy_access').insert({
        researcher_id: userId,
        pharmacy_id: pharmId
    });
    if (linkErr) {
        showError('Account created but pharmacy link failed: ' + linkErr.message);
        setAuthLoading(btn, false, 'Create Account');
        return;
    }

    if (session) {
        showLoadingOverlay();
        await loadDashboard();
    } else {
        showSuccess('Account created! Check your email to confirm, then sign in.');
        showLogin();
    }
    setAuthLoading(btn, false, 'Create Account');
}

function handleLogout() {
    sb.auth.signOut();
    session = null;
    researcher = null;
    pharmacyMap = {};
    participantsList = [];
    currentParticipant = null;
    destroyAllCharts();

    document.getElementById('dashboardScreen').style.display = 'none';
    document.getElementById('authScreen').style.display = 'flex';
    document.getElementById('loginEmail').value = '';
    document.getElementById('loginPassword').value = '';
    showLogin();
}

// ═════════════════════════════════════════════════════
// LOADING OVERLAY
// ═════════════════════════════════════════════════════

function showLoadingOverlay() {
    document.getElementById('loadingOverlay').style.display = 'flex';
}

function hideLoadingOverlay() {
    document.getElementById('loadingOverlay').style.display = 'none';
}

// ═════════════════════════════════════════════════════
// DASHBOARD LOADER
// ═════════════════════════════════════════════════════

async function loadDashboard() {
    const userId = session.user.id;

    try {
        // Get researcher record
        const { data: res } = await sb.from('researchers').select('*').eq('id', userId);
        if (!res || res.length === 0) {
            hideLoadingOverlay();
            showError('Your account is not registered as a researcher. Please sign up first.');
            session = null;
            return;
        }
        researcher = res[0];

        // Get pharmacy access
        const { data: access } = await sb.from('researcher_pharmacy_access')
            .select('pharmacy_id')
            .eq('researcher_id', userId);
        const pharmIds = (access || []).map(a => a.pharmacy_id);

        if (pharmIds.length === 0) {
            hideLoadingOverlay();
            showError('No pharmacy access assigned to your account. Contact your administrator.');
            session = null;
            return;
        }

        // Get pharmacies
        const { data: pharms } = await sb.from('pharmacies').select('*').in('id', pharmIds);
        pharmacyMap = {};
        (pharms || []).forEach(p => pharmacyMap[p.id] = p);

        // Get participants
        const { data: parts } = await sb.from('participants')
            .select('*')
            .in('pharmacy_id', pharmIds)
            .order('id');

        participantsList = (parts || []).map(p => ({
            ...p,
            pharmacy_name:  pharmacyMap[p.pharmacy_id]?.name  || p.pharmacy_id,
            pharmacy_city:  pharmacyMap[p.pharmacy_id]?.city  || '',
            pharmacy_state: pharmacyMap[p.pharmacy_id]?.state || '',
        }));

        // Update UI
        document.getElementById('authScreen').style.display  = 'none';
        document.getElementById('dashboardScreen').style.display = 'block';
        hideLoadingOverlay();

        // Header user info
        const displayName = researcher.name || researcher.email;
        document.getElementById('researcherName').textContent = displayName;
        document.getElementById('userAvatar').textContent = getInitials(displayName);

        // Summary cards
        document.getElementById('statParticipants').textContent = participantsList.length;
        document.getElementById('statPharmacies').textContent   = Object.keys(pharmacyMap).length;
        document.getElementById('statNames').textContent =
            Object.values(pharmacyMap).map(p => p.name).join(', ') || '—';

        // Table
        renderTable(participantsList);
        document.getElementById('tableFooter').textContent =
            `Showing ${participantsList.length} participant${participantsList.length !== 1 ? 's' : ''}`;

    } catch (err) {
        hideLoadingOverlay();
        showError('Failed to load dashboard: ' + err.message);
        console.error(err);
        session = null;
    }
}

// ═════════════════════════════════════════════════════
// PARTICIPANT TABLE
// ═════════════════════════════════════════════════════

function renderTable(list) {
    const tbody = document.getElementById('participantsBody');

    if (list.length === 0) {
        tbody.innerHTML = '<tr><td colspan="4" class="empty-row">No participants found</td></tr>';
        return;
    }

    tbody.innerHTML = list.map(p => {
        const loc = [p.pharmacy_city, p.pharmacy_state].filter(Boolean).join(', ') || '—';
        return `
            <tr onclick="selectParticipant('${escAttr(p.id)}')">
                <td class="pid">${escHtml(p.id)}</td>
                <td>${escHtml(p.pharmacy_name)}</td>
                <td style="color:#6b7280">${escHtml(loc)}</td>
                <td class="view-link">View →</td>
            </tr>`;
    }).join('');
}

function filterTable() {
    const q = document.getElementById('searchInput').value.toLowerCase().trim();
    if (!q) {
        renderTable(participantsList);
        document.getElementById('tableFooter').textContent =
            `Showing ${participantsList.length} participant${participantsList.length !== 1 ? 's' : ''}`;
        return;
    }
    const filtered = participantsList.filter(p =>
        p.id.toLowerCase().includes(q) ||
        (p.pharmacy_name || '').toLowerCase().includes(q) ||
        (p.pharmacy_city || '').toLowerCase().includes(q)
    );
    renderTable(filtered);
    document.getElementById('tableFooter').textContent =
        `Showing ${filtered.length} of ${participantsList.length} participants`;
}

// ═════════════════════════════════════════════════════
// DETAIL VIEW
// ═════════════════════════════════════════════════════

async function selectParticipant(pid) {
    currentParticipant = participantsList.find(p => p.id === pid);
    if (!currentParticipant) return;

    // Switch views
    document.getElementById('listView').style.display = 'none';
    document.getElementById('detailView').classList.add('active');
    document.getElementById('detailTitle').textContent      = currentParticipant.id;
    document.getElementById('detailPharmacy').textContent    = currentParticipant.pharmacy_name;
    document.getElementById('filterFrom').value = '';
    document.getElementById('filterTo').value   = '';
    document.getElementById('clearFilterBtn').style.display = 'none';

    // Show loading states
    document.getElementById('metricsGrid').innerHTML =
        '<div style="grid-column:1/-1;text-align:center;padding:60px;color:#9ca3af">Loading metrics…</div>';
    document.getElementById('sideEffectsContent').innerHTML =
        '<div class="empty-state">Loading…</div>';
    document.getElementById('medicationsContent').innerHTML =
        '<div class="empty-state">Loading…</div>';
    document.getElementById('snapshotRow').innerHTML = '';

    // Fetch all data in parallel
    const [metricsRes, seRes, medRes] = await Promise.all([
        sb.from('gait_metrics').select('*').eq('participant_id', pid).order('date', { ascending: true }),
        sb.from('side_effects').select('*').eq('participant_id', pid).order('reported_at', { ascending: false }).limit(50),
        sb.from('medications').select('*').eq('participant_id', pid).order('start_date', { ascending: false }),
    ]);

    currentMetrics     = metricsRes.data  || [];
    currentSideEffects = seRes.data        || [];
    currentMedications = medRes.data       || [];

    buildSnapshots();
    buildCharts();
    renderSideEffects();
    renderMedications();
}

function backToList() {
    document.getElementById('detailView').classList.remove('active');
    document.getElementById('listView').style.display = 'block';
    destroyAllCharts();
    currentParticipant = null;
    currentMetrics     = [];
    currentSideEffects = [];
    currentMedications = [];
}

function clearDateFilters() {
    document.getElementById('filterFrom').value = '';
    document.getElementById('filterTo').value   = '';
    document.getElementById('clearFilterBtn').style.display = 'none';
    buildCharts();
    buildSnapshots();
}

function reloadCharts() {
    const f = document.getElementById('filterFrom').value;
    const t = document.getElementById('filterTo').value;
    document.getElementById('clearFilterBtn').style.display = (f || t) ? 'inline-flex' : 'none';
    buildCharts();
    buildSnapshots();
}

function getFilteredMetrics() {
    let d = [...currentMetrics];
    const f = document.getElementById('filterFrom').value;
    const t = document.getElementById('filterTo').value;
    if (f) d = d.filter(r => r.date >= f);
    if (t) d = d.filter(r => r.date <= t);
    return d;
}

// ═════════════════════════════════════════════════════
// SNAPSHOTS (latest values)
// ═════════════════════════════════════════════════════

function buildSnapshots() {
    const data = getFilteredMetrics();
    const row  = document.getElementById('snapshotRow');

    if (data.length === 0) {
        row.innerHTML = '';
        return;
    }

    row.innerHTML = METRICS.map(m => {
        const vals = data.filter(d => d[m.key] != null);
        if (vals.length === 0) return `
            <div class="snapshot-card">
                <div class="snap-label">${m.label}</div>
                <div class="snap-value" style="color:#d1d5db">—</div>
            </div>`;

        const latest   = vals[vals.length - 1][m.key];
        const prev     = vals.length > 1 ? vals[vals.length - 2][m.key] : null;
        let changeHtml = '';

        if (prev != null) {
            const diff    = latest - prev;
            const pct     = prev !== 0 ? ((diff / Math.abs(prev)) * 100).toFixed(1) : '0.0';
            const isWorse = (m.worsens === 'increase' && diff > 0) || (m.worsens === 'decrease' && diff < 0);
            const cls     = Math.abs(diff) < 0.001 ? 'neutral' : (isWorse ? 'up' : 'down');
            const arrow   = diff > 0 ? '↑' : diff < 0 ? '↓' : '—';
            changeHtml    = `<div class="snap-change ${cls}">${arrow} ${Math.abs(pct)}%</div>`;
        }

        return `
            <div class="snapshot-card">
                <div class="snap-label">${m.label}</div>
                <div class="snap-value">${latest.toFixed(3)}</div>
                ${changeHtml}
            </div>`;
    }).join('');
}

// ═════════════════════════════════════════════════════
// CHARTS
// ═════════════════════════════════════════════════════

function destroyAllCharts() {
    Object.values(chartInstances).forEach(c => c.destroy());
    chartInstances = {};
}

function buildCharts() {
    destroyAllCharts();
    const grid = document.getElementById('metricsGrid');
    const data = getFilteredMetrics();

    grid.innerHTML = METRICS.map(m => {
        const alertStatus = analyzeMetric(data, m);
        const badgeHtml   = alertStatus.status === 'warning'
            ? '<span class="alert-badge warning">⚠ Alert</span>'
            : '<span class="alert-badge normal">✓ Normal</span>';

        return `
            <div class="metric-card">
                <div class="metric-header">
                    <h3>${m.label}</h3>
                    <div style="display:flex;align-items:center;gap:8px">
                        ${badgeHtml}
                        <span class="metric-unit">${m.unit}</span>
                    </div>
                </div>
                <div class="chart-box"><canvas id="chart-${m.key}"></canvas></div>
            </div>`;
    }).join('');

    METRICS.forEach(m => createChart(m, data));
}

function analyzeMetric(data, metric) {
    const vals = data.filter(d => d[metric.key] != null).map(d => d[metric.key]);
    if (vals.length < 14) return { status: 'normal', message: 'Insufficient data' };

    const ma       = calcMovingAverage(vals, 14);
    const baseline = ma.slice(0, -1);
    const mean     = baseline.reduce((a, b) => a + b, 0) / baseline.length;
    const sd       = Math.sqrt(baseline.reduce((sq, n) => sq + (n - mean) ** 2, 0) / baseline.length);
    const current  = vals[vals.length - 1];

    if (metric.worsens === 'increase' && current > mean + 2 * sd) {
        return { status: 'warning', message: 'Above 2SD threshold' };
    }
    if (metric.worsens === 'decrease' && current < mean - 2 * sd) {
        return { status: 'warning', message: 'Below 2SD threshold' };
    }
    return { status: 'normal', message: 'Within normal range' };
}

function calcMovingAverage(values, window) {
    return values.map((_, i) => {
        const sl = values.slice(Math.max(0, i - window + 1), i + 1);
        return sl.reduce((a, b) => a + b, 0) / sl.length;
    });
}

function createChart(metric, data) {
    const vals = data
        .filter(d => d[metric.key] != null)
        .map(d => ({ x: new Date(d.date), y: d[metric.key] }))
        .sort((a, b) => a.x - b.x);

    const canvas = document.getElementById('chart-' + metric.key);
    if (!vals.length) {
        canvas.parentElement.innerHTML = '<div class="chart-empty">No data available for this period</div>';
        return;
    }

    const rawY   = vals.map(v => v.y);
    const ma     = calcMovingAverage(rawY, 14);
    const maData = vals.map((v, i) => ({ x: v.x, y: ma[i] }));

    const mean = rawY.reduce((a, b) => a + b, 0) / rawY.length;
    const sd   = Math.sqrt(rawY.reduce((a, v) => a + (v - mean) ** 2, 0) / (rawY.length - 1 || 1));
    const threshold = metric.worsens === 'increase' ? mean + 2 * sd : mean - 2 * sd;

    // Build medication annotation lines for active meds
    const medAnnotations = [];
    currentMedications.forEach(med => {
        const start = new Date(med.start_date);
        if (start >= vals[0].x && start <= vals[vals.length - 1].x) {
            medAnnotations.push({
                x: start,
                label: med.medication_name + ' (' + (med.dose || '') + ')'
            });
        }
    });

    // Medication lines plugin
    const medPlugin = {
        id: 'medLines_' + metric.key,
        afterDatasetsDraw: (chart) => {
            if (!medAnnotations.length) return;
            const ctx    = chart.ctx;
            const xScale = chart.scales.x;
            const area   = chart.chartArea;

            ctx.save();
            medAnnotations.forEach(ann => {
                const x = xScale.getPixelForValue(ann.x);
                if (x < area.left || x > area.right) return;

                // Vertical line
                ctx.strokeStyle = 'rgba(251, 191, 36, 0.25)';
                ctx.lineWidth   = 2;
                ctx.setLineDash([]);
                ctx.beginPath();
                ctx.moveTo(x, area.top);
                ctx.lineTo(x, area.bottom);
                ctx.stroke();

                // Label
                ctx.font      = 'bold 9px sans-serif';
                ctx.fillStyle = 'rgba(251, 191, 36, 0.9)';
                const tw = ctx.measureText(ann.label).width;
                const lx = Math.min(Math.max(x - tw / 2, area.left), area.right - tw - 8);
                ctx.fillRect(lx - 4, area.top - 16, tw + 8, 14);
                ctx.fillStyle = '#78350f';
                ctx.textAlign = 'left';
                ctx.fillText(ann.label, lx, area.top - 5);
            });
            ctx.restore();
        }
    };

    chartInstances[metric.key] = new Chart(canvas.getContext('2d'), {
        type: 'line',
        data: {
            datasets: [
                {
                    label: 'Daily',
                    data: vals,
                    borderColor: metric.color,
                    backgroundColor: metric.color + '15',
                    borderWidth: 1.5,
                    pointRadius: 2,
                    pointHoverRadius: 5,
                    pointBackgroundColor: metric.color,
                    tension: 0.1,
                    fill: true,
                },
                {
                    label: '14-Day MA',
                    data: maData,
                    borderColor: metric.color,
                    borderWidth: 2.5,
                    borderDash: [6, 3],
                    pointRadius: 0,
                    fill: false,
                    tension: 0.3,
                },
                {
                    label: (metric.worsens === 'increase' ? '+' : '−') + '2 SD',
                    data: vals.map(v => ({ x: v.x, y: threshold })),
                    borderColor: 'rgba(229, 62, 62, 0.4)',
                    borderWidth: 1.5,
                    borderDash: [8, 4],
                    pointRadius: 0,
                    fill: false,
                },
                {
                    label: 'Mean',
                    data: vals.map(v => ({ x: v.x, y: mean })),
                    borderColor: 'rgba(160, 174, 192, 0.4)',
                    borderWidth: 1,
                    borderDash: [4, 4],
                    pointRadius: 0,
                    fill: false,
                },
            ]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: 'index', intersect: false },
            layout: { padding: { top: medAnnotations.length ? 24 : 4 } },
            scales: {
                x: {
                    type: 'time',
                    time: { unit: 'day', displayFormats: { day: 'MMM d' } },
                    ticks: { font: { size: 10 }, color: '#9ca3af', maxRotation: 0 },
                    grid: { display: false },
                },
                y: {
                    ticks: { font: { size: 10 }, color: '#9ca3af' },
                    grid: { color: '#f3f4f6' },
                }
            },
            plugins: {
                legend: {
                    display: true,
                    position: 'bottom',
                    labels: { padding: 10, boxWidth: 28, font: { size: 11 }, usePointStyle: false }
                },
                tooltip: {
                    backgroundColor: '#fff',
                    titleColor: '#111',
                    bodyColor: '#374151',
                    borderColor: '#e2e8f0',
                    borderWidth: 1,
                    cornerRadius: 8,
                    padding: 10,
                    titleFont: { size: 12, weight: '600' },
                    bodyFont: { size: 12 },
                    callbacks: {
                        label: ctx => {
                            return ctx.dataset.label + ': ' +
                                (ctx.parsed.y != null ? ctx.parsed.y.toFixed(3) : 'N/A');
                        },
                        footer: items => {
                            const date = new Date(items[0].parsed.x);
                            const active = currentMedications.filter(m => {
                                const s = new Date(m.start_date);
                                const e = m.end_date ? new Date(m.end_date) : new Date();
                                return date >= s && date <= e;
                            });
                            return active.length
                                ? '\nActive Meds: ' + active.map(m => m.medication_name).join(', ')
                                : '';
                        }
                    }
                }
            }
        },
        plugins: [medPlugin]
    });
}

// ═════════════════════════════════════════════════════
// SIDE EFFECTS
// ═════════════════════════════════════════════════════

function renderSideEffects() {
    const el = document.getElementById('sideEffectsContent');
    document.getElementById('seCount').textContent = currentSideEffects.length;

    if (!currentSideEffects.length) {
        el.innerHTML = '<div class="empty-state">No reports filed</div>';
        return;
    }

    el.innerHTML = `
        <table class="se-table">
            <thead><tr><th>Date</th><th>Report</th></tr></thead>
            <tbody>${currentSideEffects.map(s => `
                <tr>
                    <td class="se-date">${fmtDate(s.reported_at)}</td>
                    <td>${escHtml(s.message || '')}</td>
                </tr>`).join('')}
            </tbody>
        </table>`;
}

// ═════════════════════════════════════════════════════
// MEDICATIONS
// ═════════════════════════════════════════════════════

function renderMedications() {
    const el = document.getElementById('medicationsContent');
    document.getElementById('medCount').textContent = currentMedications.length;

    if (!currentMedications.length) {
        el.innerHTML = '<div class="empty-state">No medications recorded</div>';
        return;
    }

    const freqLabels = {
        daily: 'Daily', weekly: 'Weekly', biweekly: 'Every 2 Weeks',
        monthly: 'Monthly', asneeded: 'As Needed'
    };

    el.innerHTML = `
        <table class="med-table">
            <thead><tr><th>Medication</th><th>Dose</th><th>Frequency</th><th>Started</th><th>Status</th></tr></thead>
            <tbody>${currentMedications.map(m => {
                const isActive = !m.end_date;
                return `
                <tr>
                    <td class="med-name">${escHtml(m.medication_name || '')}</td>
                    <td>${escHtml(m.dose || '—')}</td>
                    <td>${freqLabels[m.frequency] || m.frequency || '—'}</td>
                    <td style="color:#6b7280">${fmtDate(m.start_date)}</td>
                    <td>
                        ${isActive
                            ? '<span class="med-status active">Active</span>'
                            : '<span class="med-status ended">Ended ' + fmtDate(m.end_date) + '</span>'}
                    </td>
                </tr>`;
            }).join('')}
            </tbody>
        </table>`;
}

// ═════════════════════════════════════════════════════
// CSV EXPORT
// ═════════════════════════════════════════════════════

function exportParticipantCSV() {
    if (!currentParticipant) return;

    let csv = 'Date,Walking Speed (m/s),Step Length (m),Asymmetry (%),Double Support (%),Steadiness\n';
    currentMetrics.forEach(m => {
        csv += `${m.date},${m.walking_speed ?? ''},${m.walking_step_length ?? ''},${m.walking_asymmetry ?? ''},${m.double_support_time ?? ''},${m.walking_steadiness ?? ''}\n`;
    });

    csv += '\n\nSide Effects\nDate,Message\n';
    currentSideEffects.forEach(s => {
        csv += `${fmtDate(s.reported_at)},"${(s.message || '').replace(/"/g, '""')}"\n`;
    });

    csv += '\n\nMedications\nMedication,Dose,Frequency,Start Date,End Date\n';
    currentMedications.forEach(m => {
        csv += `"${(m.medication_name || '').replace(/"/g, '""')}","${m.dose || ''}","${m.frequency || ''}",${m.start_date || ''},${m.end_date || ''}\n`;
    });

    downloadCSV(csv, `stepforward_${currentParticipant.id}_${todayStr()}.csv`);
}

async function exportAllCSV() {
    if (!participantsList.length) return;

    const btn = document.querySelector('.toolbar-actions .btn-primary');
    const origText = btn.innerHTML;
    btn.innerHTML = '<span class="btn-spinner" style="display:inline-block"></span> Exporting…';
    btn.disabled  = true;

    try {
        const ids = participantsList.map(p => p.id);
        const { data: allM } = await sb.from('gait_metrics')
            .select('*')
            .in('participant_id', ids)
            .order('date', { ascending: true });

        let csv = 'Participant ID,Pharmacy,Date,Walking Speed,Step Length,Asymmetry,Double Support,Steadiness\n';
        participantsList.forEach(p => {
            (allM || []).filter(m => m.participant_id === p.id).forEach(m => {
                csv += `${p.id},"${p.pharmacy_name}",${m.date},${m.walking_speed ?? ''},${m.walking_step_length ?? ''},${m.walking_asymmetry ?? ''},${m.double_support_time ?? ''},${m.walking_steadiness ?? ''}\n`;
            });
        });

        downloadCSV(csv, `stepforward_all_participants_${todayStr()}.csv`);
    } catch (err) {
        console.error('Export failed:', err);
    } finally {
        btn.innerHTML = origText;
        btn.disabled  = false;
    }
}

function downloadCSV(csv, filename) {
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
    const a    = document.createElement('a');
    a.href     = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    URL.revokeObjectURL(a.href);
}

// ═════════════════════════════════════════════════════
// UTILITIES
// ═════════════════════════════════════════════════════

function fmtDate(d) {
    if (!d) return '—';
    return new Date(d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function todayStr() {
    return new Date().toISOString().split('T')[0];
}

function escHtml(s) {
    const d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
}

function escAttr(s) {
    return s.replace(/'/g, "\\'").replace(/"/g, '&quot;');
}

function getInitials(name) {
    if (!name) return '?';
    const parts = name.trim().split(/\s+/);
    if (parts.length >= 2) return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
    return name.substring(0, 2).toUpperCase();
}

// ═════════════════════════════════════════════════════
// INIT — Check for existing session
// ═════════════════════════════════════════════════════

(async () => {
    const { data: { session: existing } } = await sb.auth.getSession();
    if (existing) {
        session = existing;
        showLoadingOverlay();
        await loadDashboard();
    }
})();