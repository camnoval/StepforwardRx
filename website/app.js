// Initialize Supabase client
const supabaseClient = window.supabase.createClient(
    'https://tcagznodtcvlnhharmgj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU'
);

let currentParticipant = null;
let chartInstances = {};
let activeMedications = {}; // Track which medications are toggled on

const METRICS = {
    double_support_time: { label: 'Double Support Time', unit: 's', worsens: 'increase' },
    walking_asymmetry: { label: 'Walking Asymmetry', unit: '%', worsens: 'increase' },
    walking_speed: { label: 'Walking Speed', unit: 'm/s', worsens: 'decrease' },
    walking_step_length: { label: 'Step Length', unit: 'm', worsens: 'decrease' },
    walking_steadiness: { label: 'Walking Steadiness', unit: '%', worsens: 'decrease' }
};

// Load all participants
async function loadParticipants() {
    console.log('Loading participants...');
    
    const { data, error } = await supabaseClient
        .from('participants')
        .select('*')
        .order('id');

    console.log('Supabase response:', { data, error });

    if (error) {
        console.error('Error loading participants:', error);
        document.getElementById('participantsList').innerHTML = 
            `<div class="empty-state">
                <h3>⚠️ Database Error</h3>
                <p>${error.message}</p>
                <p style="font-size: 0.85rem; margin-top: 1rem;">Check the browser console (F12) for details</p>
            </div>`;
        return;
    }

    if (!data || data.length === 0) {
        document.getElementById('participantsList').innerHTML = 
            `<div class="empty-state">
                <h3>No participants found</h3>
                <p>The 'participants' table exists but is empty.</p>
                <p style="font-size: 0.85rem; margin-top: 1rem;">Add participants to your Supabase database to get started.</p>
                <button class="btn btn-primary" onclick="showTestData()" style="margin-top: 1rem;">Add Test Data</button>
            </div>`;
        return;
    }

    const html = data.map(p => `
        <div class="participant-card" onclick="selectParticipant('${p.id}')">
            <h3>Participant ${p.id}</h3>
            <div class="stats">Click to view details</div>
        </div>
    `).join('');

    document.getElementById('participantsList').innerHTML = html;
}

// Select a participant to view details
async function selectParticipant(participantId) {
    currentParticipant = participantId;
    
    document.querySelectorAll('.participant-card').forEach(card => {
        card.classList.remove('active');
    });
    event.target.closest('.participant-card').classList.add('active');

    document.getElementById('detailTitle').textContent = `Participant ${participantId}`;
    document.getElementById('detailView').classList.add('active');

    // Load medications FIRST, then load charts
    await loadMedications(currentParticipant);
    await loadParticipantData(currentParticipant);
}

// Close detail view
function closeDetail() {
    document.getElementById('detailView').classList.remove('active');
    document.querySelectorAll('.participant-card').forEach(card => {
        card.classList.remove('active');
    });
    currentParticipant = null;
    
    Object.values(chartInstances).forEach(chart => chart.destroy());
    chartInstances = {};
}

// Load participant gait metrics
async function loadParticipantData(participantId) {
    console.log('Loading data for participant:', participantId);
    
    const { data, error } = await supabaseClient
        .from('gait_metrics')
        .select('*')
        .eq('participant_id', participantId)
        .order('date');

    console.log('Gait metrics response:', { data, error });

    if (error) {
        console.error('Error loading metrics:', error);
        return;
    }

    const metricsHtml = Object.keys(METRICS).map(metric => {
        const alertStatus = analyzeMetric(data, metric);
        return `
            <div class="metric-card">
                <div class="metric-header">
                    <h3>${METRICS[metric].label}</h3>
                    <span class="alert-badge ${alertStatus.status}">
                        ${alertStatus.status === 'warning' ? '⚠️ Alert' : '✓ Normal'}
                    </span>
                </div>
                <div class="chart-container">
                    <canvas id="chart-${metric}"></canvas>
                </div>
            </div>
        `;
    }).join('');

    document.getElementById('metricsContainer').innerHTML = metricsHtml;

    // Create all charts sequentially to ensure proper rendering
    for (const metric of Object.keys(METRICS)) {
        await createChart(metric, data, participantId);
    }
}

// Analyze metric for alerts
function analyzeMetric(data, metric) {
    const values = data
        .filter(d => d[metric] != null)
        .map(d => ({ date: new Date(d.date), value: d[metric] }))
        .sort((a, b) => a.date - b.date);

    if (values.length < 14) {
        return { status: 'normal', message: 'Insufficient data' };
    }

    const movingAvg = calculateMovingAverage(values.map(v => v.value), 14);
    const baseline = movingAvg.slice(0, -1);
    const mean = baseline.reduce((a, b) => a + b, 0) / baseline.length;
    const std = Math.sqrt(baseline.reduce((sq, n) => sq + Math.pow(n - mean, 2), 0) / baseline.length);

    const currentValue = values[values.length - 1].value;
    const worsens = METRICS[metric].worsens;

    if (worsens === 'increase' && currentValue > mean + 2 * std) {
        return { status: 'warning', message: 'Above 2SD threshold' };
    }
    if (worsens === 'decrease' && currentValue < mean - 2 * std) {
        return { status: 'warning', message: 'Below 2SD threshold' };
    }

    return { status: 'normal', message: 'Within normal range' };
}

// Calculate moving average
function calculateMovingAverage(values, window) {
    const result = [];
    for (let i = 0; i < values.length; i++) {
        const start = Math.max(0, i - window + 1);
        const subset = values.slice(start, i + 1);
        result.push(subset.reduce((a, b) => a + b, 0) / subset.length);
    }
    return result;
}

// Create chart for a metric
async function createChart(metric, data, participantId) {
    const values = data
        .filter(d => d[metric] != null)
        .map(d => ({ x: new Date(d.date), y: d[metric] }))
        .sort((a, b) => a.x - b.x);

    if (values.length === 0) {
        document.getElementById(`chart-${metric}`).parentElement.innerHTML = 
            '<p style="text-align: center; color: #718096; padding: 2rem;">No data available</p>';
        return;
    }

    const movingAvg = calculateMovingAverage(values.map(v => v.y), 14);
    const movingAvgData = values.map((v, i) => ({ x: v.x, y: movingAvg[i] }));

    const baseline = movingAvg.slice(0, -1);
    const mean = baseline.reduce((a, b) => a + b, 0) / baseline.length;
    const std = Math.sqrt(baseline.reduce((sq, n) => sq + Math.pow(n - mean, 2), 0) / baseline.length);

    const worsens = METRICS[metric].worsens;
    const alertThreshold = worsens === 'increase' ? mean + 2 * std : mean - 2 * std;

    const { data: meds } = await supabaseClient
        .from('medications')
        .select('*')
        .eq('participant_id', participantId)
        .order('start_date');

    const activeMeds = meds?.filter(m => activeMedications[m.id]) || [];
    
    // Generate all medication dose dates with full med info
    const allMedicationDoses = [];
    activeMeds.forEach(med => {
        const doses = generateDoseDates(med);
        doses.forEach(dose => {
            allMedicationDoses.push({
                date: dose,
                medication: med.medication_name,
                dose: med.dose,
                medId: med.id,
                color: 'rgba(251, 191, 36, 0.8)'
            });
        });
    });

    console.log(`[${metric}] Medication doses to display:`, allMedicationDoses);
    console.log(`[${metric}] Active meds:`, activeMeds);

    const ctx = document.getElementById(`chart-${metric}`).getContext('2d');
    
    if (chartInstances[metric]) {
        chartInstances[metric].destroy();
    }

    // Custom plugin to draw medication lines
    const medicationLinesPlugin = {
        id: 'medicationLines',
        afterDatasetsDraw: (chart) => {
            const ctx = chart.ctx;
            const xScale = chart.scales.x;
            const yScale = chart.scales.y;
            const chartArea = chart.chartArea;
            
            ctx.save();
            
            console.log(`[${metric}] Drawing medications, chartArea:`, chartArea);
            
            // Group medications by unique med_id to show each medication separately
            const medicationGroups = {};
            allMedicationDoses.forEach(dose => {
                if (!medicationGroups[dose.medId]) {
                    medicationGroups[dose.medId] = {
                        name: dose.medication,
                        doseAmount: dose.dose,
                        dates: []
                    };
                }
                medicationGroups[dose.medId].dates.push(dose.date);
            });
            
            console.log(`[${metric}] Medication groups:`, medicationGroups);
            
            // Draw all medication lines
            allMedicationDoses.forEach((dose) => {
                const x = xScale.getPixelForValue(dose.date);
                const yTop = chartArea.top;
                const yBottom = chartArea.bottom;
                
                // Draw vertical line with 20% opacity
                ctx.strokeStyle = 'rgba(251, 191, 36, 0.2)';
                ctx.lineWidth = 3;
                ctx.beginPath();
                ctx.moveTo(x, yTop);
                ctx.lineTo(x, yBottom);
                ctx.stroke();
            });
            
            // Draw labels for each unique medication
            let labelYOffset = 0;
            Object.values(medicationGroups).forEach((medGroup, groupIndex) => {
                // Find the first date for this medication to position the label
                const firstDate = medGroup.dates[0];
                let x = xScale.getPixelForValue(firstDate);
                
                // Create label text with dose
                const labelText = `${medGroup.name} (${medGroup.doseAmount})`;
                
                // Measure text width for proper background sizing
                ctx.font = 'bold 10px sans-serif';
                const textWidth = ctx.measureText(labelText).width;
                const padding = 6;
                
                // Check if label would be cut off on the right edge
                const labelWidth = textWidth + padding * 2;
                const labelRight = x + labelWidth / 2;
                if (labelRight > chartArea.right) {
                    x = chartArea.right - labelWidth / 2;
                }
                
                // Check if label would be cut off on the left edge
                const labelLeft = x - labelWidth / 2;
                if (labelLeft < chartArea.left) {
                    x = chartArea.left + labelWidth / 2;
                }
                
                const labelY = chartArea.top - 10 - labelYOffset;
                
                // Draw background box
                ctx.fillStyle = 'rgba(251, 191, 36, 0.9)';
                ctx.fillRect(x - textWidth/2 - padding, labelY, textWidth + padding * 2, 18);
                
                // Draw text
                ctx.fillStyle = '#78350f';
                ctx.textAlign = 'center';
                ctx.fillText(labelText, x, labelY + 13);
                
                // Stack labels vertically if multiple medications
                labelYOffset += 22;
            });
            
            ctx.restore();
        }
    };

    chartInstances[metric] = new Chart(ctx, {
        type: 'line',
        data: {
            datasets: [
                {
                    label: 'Actual',
                    data: values,
                    borderColor: '#667eea',
                    backgroundColor: 'rgba(102, 126, 234, 0.1)',
                    borderWidth: 2,
                    pointRadius: 3,
                    pointHoverRadius: 5
                },
                {
                    label: '14-Day MA',
                    data: movingAvgData,
                    borderColor: '#48bb78',
                    borderWidth: 2,
                    borderDash: [5, 5],
                    pointRadius: 0,
                    fill: false
                },
                {
                    label: 'Alert Threshold',
                    data: values.map(v => ({ x: v.x, y: alertThreshold })),
                    borderColor: 'rgba(229, 62, 62, 0.5)',
                    borderWidth: 2,
                    borderDash: [10, 5],
                    pointRadius: 0,
                    fill: false
                }
            ]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            layout: {
                padding: {
                    top: 30  // Just enough padding for medication labels
                }
            },
            scales: {
                x: {
                    type: 'time',
                    time: {
                        unit: 'day',
                        displayFormats: {
                            day: 'MMM d'
                        }
                    },
                    title: {
                        display: true,
                        text: 'Date'
                    }
                },
                y: {
                    title: {
                        display: true,
                        text: `${METRICS[metric].label} (${METRICS[metric].unit})`
                    }
                }
            },
            plugins: {
                legend: {
                    display: true,
                    position: 'bottom',
                    labels: {
                        padding: 10,
                        boxWidth: 40
                    }
                },
                tooltip: {
                    mode: 'index',
                    intersect: false,
                    callbacks: {
                        footer: function(tooltipItems) {
                            const date = new Date(tooltipItems[0].parsed.x);
                            const activeOnDate = activeMeds.filter(m => {
                                const start = new Date(m.start_date);
                                const end = m.end_date ? new Date(m.end_date) : new Date();
                                return date >= start && date <= end;
                            });
                            
                            if (activeOnDate.length > 0) {
                                return '\nActive Meds: ' + activeOnDate.map(m => m.medication_name).join(', ');
                            }
                            return '';
                        }
                    }
                }
            }
        },
        plugins: [medicationLinesPlugin]
    });
}

// Generate dose dates based on medication frequency
function generateDoseDates(medication) {
    const start = new Date(medication.start_date);
    const end = medication.end_date ? new Date(medication.end_date) : new Date();
    const doses = [];
    
    let intervalDays;
    switch(medication.frequency) {
        case 'daily':
            intervalDays = 1;
            break;
        case 'weekly':
            intervalDays = 7;
            break;
        case 'biweekly':
            intervalDays = 14;
            break;
        case 'monthly':
            intervalDays = 30;
            break;
        case 'asneeded':
            // For as-needed, just show start and end
            doses.push(start);
            if (medication.end_date) doses.push(end);
            return doses;
        default:
            intervalDays = 1;
    }
    
    let currentDate = new Date(start);
    while (currentDate <= end) {
        doses.push(new Date(currentDate));
        currentDate.setDate(currentDate.getDate() + intervalDays);
    }
    
    return doses;
}

// Load medications for a participant
async function loadMedications(participantId) {
    const { data, error } = await supabaseClient
        .from('medications')
        .select('*')
        .eq('participant_id', participantId)
        .order('start_date', { ascending: false });

    if (error) {
        console.error('Error loading medications:', error);
        return;
    }

    if (!data || data.length === 0) {
        document.getElementById('medicationsList').innerHTML = 
            '<div class="empty-state"><p>No medications recorded</p></div>';
        return;
    }

    // Initialize all medications as active
    data.forEach(med => {
        if (activeMedications[med.id] === undefined) {
            activeMedications[med.id] = true;
        }
    });

    const frequencyLabels = {
        daily: 'Daily',
        weekly: 'Weekly',
        biweekly: 'Every 2 Weeks',
        monthly: 'Monthly',
        asneeded: 'As Needed'
    };

    const html = data.map(med => `
        <div class="medication-item">
            <div class="medication-info">
                <h4>${med.medication_name}</h4>
                <div class="details">
                    Dose: ${med.dose} | 
                    Frequency: ${frequencyLabels[med.frequency] || med.frequency || 'Not specified'} | 
                    Started: ${new Date(med.start_date).toLocaleDateString()} 
                    ${med.end_date ? `| Ended: ${new Date(med.end_date).toLocaleDateString()}` : '| Ongoing'}
                </div>
            </div>
            <div class="medication-controls">
                <div class="medication-toggle">
                    <span class="toggle-label">Show</span>
                    <div class="toggle-switch ${activeMedications[med.id] ? 'active' : ''}" 
                         onclick="toggleMedication(${med.id})"></div>
                </div>
                <button class="btn-delete" onclick="deleteMedication(${med.id})">Delete</button>
            </div>
        </div>
    `).join('');

    document.getElementById('medicationsList').innerHTML = html;
}

// Toggle medication visibility on charts
async function toggleMedication(medId) {
    activeMedications[medId] = !activeMedications[medId];
    
    // Update toggle UI
    const toggles = document.querySelectorAll('.toggle-switch');
    toggles.forEach(toggle => {
        const medIdFromOnclick = toggle.getAttribute('onclick').match(/\d+/)[0];
        if (parseInt(medIdFromOnclick) === medId) {
            if (activeMedications[medId]) {
                toggle.classList.add('active');
            } else {
                toggle.classList.remove('active');
            }
        }
    });
    
    // Reload all charts to show/hide medication markers
    await loadParticipantData(currentParticipant);
}

// Delete medication
async function deleteMedication(medId) {
    if (!confirm('Are you sure you want to delete this medication?')) {
        return;
    }
    
    console.log('Attempting to delete medication ID:', medId);
    
    const { data, error } = await supabaseClient
        .from('medications')
        .delete()
        .eq('id', medId);
    
    console.log('Delete response:', { data, error });
    
    if (error) {
        alert('Error deleting medication: ' + error.message);
        console.error('Medication delete error:', error);
        return;
    }
    
    // Remove from active medications tracking
    delete activeMedications[medId];
    
    console.log('Medication deleted successfully, reloading...');
    
    // Reload medications list and charts
    await loadMedications(currentParticipant);
    await loadParticipantData(currentParticipant);
}

// Open medication modal
function openMedicationModal() {
    document.getElementById('medicationModal').classList.add('active');
}

// Close medication modal
function closeMedicationModal() {
    document.getElementById('medicationModal').classList.remove('active');
    document.getElementById('medicationForm').reset();
}

// Handle medication form submission
document.getElementById('medicationForm').addEventListener('submit', async (e) => {
    e.preventDefault();

    const { error } = await supabaseClient
        .from('medications')
        .insert([{
            participant_id: currentParticipant,
            medication_name: document.getElementById('medName').value,
            dose: document.getElementById('medDose').value,
            frequency: document.getElementById('medFrequency').value,
            start_date: document.getElementById('medStartDate').value,
            end_date: document.getElementById('medEndDate').value || null
        }]);

    if (error) {
        alert('Error adding medication: ' + error.message);
        console.error('Medication insert error:', error);
        return;
    }

    closeMedicationModal();
    await loadMedications(currentParticipant);
    await loadParticipantData(currentParticipant);
});

// Test data insertion function
async function showTestData() {
    if (!confirm('This will add 3 test participants and 30 days of sample data. Continue?')) return;
    
    console.log('Adding test data...');
    
    // Add test participants
    const participants = ['P001', 'P002', 'P003'];
    for (const pid of participants) {
        const { error } = await supabaseClient
            .from('participants')
            .insert([{ id: pid }]);
        if (error) console.error('Error adding participant:', error);
    }
    
    // Add sample gait metrics
    const today = new Date();
    for (let i = 0; i < 30; i++) {
        const date = new Date(today);
        date.setDate(date.getDate() - (29 - i));
        const dateStr = date.toISOString().split('T')[0];
        
        for (const pid of participants) {
            const { error } = await supabaseClient
                .from('gait_metrics')
                .insert([{
                    participant_id: pid,
                    date: dateStr,
                    double_support_time: 0.3 + Math.random() * 0.1,
                    walking_asymmetry: 2 + Math.random() * 3,
                    walking_speed: 1.2 + Math.random() * 0.3,
                    walking_step_length: 0.65 + Math.random() * 0.15,
                    walking_steadiness: 85 + Math.random() * 10
                }]);
            if (error) console.error('Error adding metrics:', error);
        }
    }
    
    alert('Test data added! Refreshing...');
    location.reload();
}

// Initialize on page load
loadParticipants();