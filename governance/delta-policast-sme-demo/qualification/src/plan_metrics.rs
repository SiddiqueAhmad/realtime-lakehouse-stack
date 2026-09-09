//! Capture every per-node metric without adding timestamps or overflowing a sum.
//! Unset/sentinel and overflowing metrics are excluded from aggregate counters,
//! but retained in the raw series for diagnosis.
use std::{collections::{BTreeMap, BTreeSet}, sync::Arc};
use datafusion::physical_plan::ExecutionPlan;
use serde_json::{json, Value};

pub fn capture(plan: &Arc<dyn ExecutionPlan>) -> (BTreeMap<String, usize>, Vec<Value>, BTreeSet<String>) {
    let mut totals = BTreeMap::new();
    let mut series = Vec::new();
    let mut unavailable = BTreeSet::new();
    fn visit(plan: &Arc<dyn ExecutionPlan>, totals: &mut BTreeMap<String, usize>, series: &mut Vec<Value>, unavailable: &mut BTreeSet<String>) {
        if let Some(metrics) = plan.metrics() {
            for metric in metrics.iter() {
                let value = metric.value();
                let name = value.name().to_string();
                let number = value.as_usize();
                series.push(json!({"node":plan.name(),"metric":name,"value":number}));
                // Epoch timestamps are observations, not additive counters.
                if name.ends_with("timestamp") { continue; }
                if number == usize::MAX {
                    totals.remove(&name);
                    unavailable.insert(name);
                    continue;
                }
                if unavailable.contains(&name) { continue; }
                match totals.get(&name).copied().unwrap_or(0).checked_add(number) {
                    Some(total) => { totals.insert(name, total); },
                    None => { totals.remove(&name); unavailable.insert(name); },
                }
            }
        }
        for child in plan.children() { visit(child, totals, series, unavailable); }
    }
    visit(plan, &mut totals, &mut series, &mut unavailable);
    (totals, series, unavailable)
}
