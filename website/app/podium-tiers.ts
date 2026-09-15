// Matches UsagePodiumTier in the Mac app. Thresholds use saved lifetime tokens.
export const podiumTiers = [
  { level: 0, id: 'white', name: 'White', threshold: '1+', tokens: 1, color: '#FAFAFA', ink: '#242424' },
  { level: 1, id: 'pearl', name: 'Pearl', threshold: '100K', tokens: 100_000, color: '#E7E7E7', ink: '#242424' },
  { level: 2, id: 'silver', name: 'Silver', threshold: '1M', tokens: 1_000_000, color: '#CDCDCD', ink: '#242424' },
  { level: 3, id: 'gold', name: 'Gold', threshold: '10M', tokens: 10_000_000, color: '#B9AD8C', ink: '#242424' },
  { level: 4, id: 'platinum', name: 'Platinum', threshold: '100M', tokens: 100_000_000, color: '#A2A6AA', ink: '#242424' },
  { level: 5, id: 'titanium', name: 'Titanium', threshold: '1B', tokens: 1_000_000_000, color: '#636970', ink: '#FAFAFA' },
  { level: 6, id: 'graphite', name: 'Graphite', threshold: '10B', tokens: 10_000_000_000, color: '#484B50', ink: '#FAFAFA' },
  { level: 7, id: 'obsidian', name: 'Obsidian', threshold: '100B', tokens: 100_000_000_000, color: '#24262A', ink: '#FAFAFA' },
  { level: 8, id: 'black', name: 'Black', threshold: '1T', tokens: 1_000_000_000_000, color: '#070808', ink: '#FAFAFA' },
] as const;
