//! Merge redundant capture damage without repainting any extra pixels.
pub(crate) type DamageRect = (u16, u16, u16, u16);

pub(crate) fn coalesce_damage(rects: Vec<DamageRect>) -> Vec<DamageRect> {
    let mut merged: Vec<DamageRect> = Vec::with_capacity(rects.len());
    for mut rect in rects {
        if rect.2 == 0 || rect.3 == 0 {
            continue;
        }
        let mut index = 0;
        while index < merged.len() {
            if let Some(union) = rectangular_union(rect, merged[index]) {
                rect = union;
                merged.swap_remove(index);
                // A union can now touch a rectangle examined earlier.
                index = 0;
            } else {
                index += 1;
            }
        }
        merged.push(rect);
    }
    merged.sort_unstable_by_key(|r| (r.1, r.0));
    merged
}

fn rectangular_union(a: DamageRect, b: DamageRect) -> Option<DamageRect> {
    let (ax, ay, aw, ah) = (
        u32::from(a.0),
        u32::from(a.1),
        u32::from(a.2),
        u32::from(a.3),
    );
    let (bx, by, bw, bh) = (
        u32::from(b.0),
        u32::from(b.1),
        u32::from(b.2),
        u32::from(b.3),
    );
    let x = ax.min(bx);
    let y = ay.min(by);
    let w = (ax + aw).max(bx + bw) - x;
    let h = (ay + ah).max(by + bh) - y;
    let overlap_w = (ax + aw).min(bx + bw).saturating_sub(ax.max(bx));
    let overlap_h = (ay + ah).min(by + bh).saturating_sub(ay.max(by));
    let area = u64::from(aw) * u64::from(ah) + u64::from(bw) * u64::from(bh)
        - u64::from(overlap_w) * u64::from(overlap_h);
    // L-shaped unions must remain separate: bounding them would add work.
    if u64::from(w) * u64::from(h) != area {
        return None;
    }
    Some((
        u16::try_from(x).ok()?,
        u16::try_from(y).ok()?,
        u16::try_from(w).ok()?,
        u16::try_from(h).ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_and_contained_damage_is_sent_once() {
        assert_eq!(
            coalesce_damage(vec![(0, 0, 64, 64), (8, 8, 8, 8), (0, 0, 64, 64)]),
            vec![(0, 0, 64, 64)]
        );
    }
    #[test]
    fn adjacent_rows_and_columns_merge_without_extra_pixels() {
        assert_eq!(
            coalesce_damage(vec![(64, 0, 64, 64), (0, 64, 128, 64), (0, 0, 64, 64)]),
            vec![(0, 0, 128, 128)]
        );
    }
    #[test]
    fn separate_and_l_shaped_damage_stays_small() {
        let damage = vec![(0, 0, 8, 64), (8, 0, 56, 8), (100, 100, 1, 1)];
        assert_eq!(coalesce_damage(damage.clone()), damage);
    }
    #[test]
    fn every_pixel_is_preserved_for_overlapping_rectangles() {
        fn pixels(rects: &[DamageRect]) -> std::collections::BTreeSet<(u16, u16)> {
            rects
                .iter()
                .flat_map(|&(x, y, w, h)| {
                    (x..x + w).flat_map(move |px| (y..y + h).map(move |py| (px, py)))
                })
                .collect()
        }
        for offset in 0..16 {
            let input = vec![
                (0, 0, 16, 16),
                (offset, 0, 16, 16),
                (4, 4, 2, 2),
                (0, 16, 16, 8),
            ];
            assert_eq!(pixels(&input), pixels(&coalesce_damage(input)));
        }
    }
    #[test]
    fn empty_damage_and_large_coordinates_are_safe() {
        assert!(coalesce_damage(vec![(0, 0, 0, 10)]).is_empty());
        assert_eq!(
            coalesce_damage(vec![(0, 0, 65535, 65535); 2]),
            vec![(0, 0, 65535, 65535)]
        );
    }
}
