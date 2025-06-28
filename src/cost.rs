#![allow(unused)]

use serde_json::Value;
use std::{collections::HashMap, hash::Hash};

pub const LITELLM_PRICELIST: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

#[derive(Debug, serde::Deserialize)]
pub struct SearchContextCostPerQuery {
    pub search_context_size_low: f64,
    pub search_context_size_medium: f64,
    pub search_context_size_high: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_fetch_cost_list() {
        let result = CostList::fetch().await.unwrap();
        assert!(!result.0.is_empty(), "Cost list should not be empty");
    }
}

#[derive(Debug, serde::Deserialize)]
pub struct ModelCostSpec {
    pub max_tokens: Option<u32>,
    pub max_input_tokens: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub input_cost_per_token: f64,
    pub output_cost_per_token: f64,
    pub output_cost_per_reasoning_token: Option<f64>,
}

#[derive(Debug, serde::Deserialize)]
pub struct CostList(pub HashMap<String, ModelCostSpec>);

impl CostList {
    pub async fn fetch() -> Result<Self, reqwest::Error> {
        let resp = reqwest::get(LITELLM_PRICELIST).await?;
        let mut list = resp.json::<HashMap<String, Value>>().await?;
        let mut out = HashMap::new();

        list.drain().skip(1).for_each(|(model, val)| {
            let Ok(spec) = serde_json::from_value::<ModelCostSpec>(val) else {
                return;
            };

            out.insert(model, spec);
        });

        Ok(CostList(out))
    }

    pub fn calc_cost(&self, model: &str, tokencount: i32) -> f32 {
        0.0
    }
}
