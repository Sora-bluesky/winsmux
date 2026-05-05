const PALETTE: &[&str] = &[
    "#EF9F27",
    "#D4537E",
    "#378ADD",
    "#1D9E75",
    "#7F77DD",
    "#D85A30",
    "#639922",
    "#A32D2D",
];

pub fn color_for(branch_id: u64) -> &'static str {
    PALETTE[(branch_id as usize) % PALETTE.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_mapping_is_deterministic() {
        assert_eq!(color_for(0), "#EF9F27");
        assert_eq!(color_for(8), "#EF9F27");
        assert_eq!(color_for(9), "#D4537E");
    }
}
