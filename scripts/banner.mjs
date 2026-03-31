#!/usr/bin/env node
import { renderFilled } from 'oh-my-logo';

const WINSMUX_PALETTE = ['#148CDC', '#1996E6', '#1DA1F2', '#3CB4F8', '#64C8FC'];

async function showBanner() {
  await renderFilled('WINSMUX', {
    palette: WINSMUX_PALETTE,
    font: 'block',
    letterSpacing: 1,
  });

  console.log('');
  console.log('\x1b[38;2;100;200;252m$ winsmux\x1b[0m');
  console.log('\x1b[38;2;140;140;160mWindows-native multiplexer for AI agents\x1b[0m');
  console.log('\x1b[38;2;100;110;130mPowered by psmux backend \u2014 no WSL2 required\x1b[0m');
}

showBanner().catch(console.error);
