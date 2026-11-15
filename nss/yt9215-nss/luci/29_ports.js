'use strict';
'require baseclass';
'require fs';

/* CR8816 NSS build: yt921x (DSA) is unbound and the lan1..wan netdevs do not
 * exist, so the stock Port status panel shows "no link" forever. yt9215-nss
 * exports the front ports instead; this panel reads them. Without that file
 * (NSS off, DSA bound) the stock panel, kept as view/status/ports_dsa.js,
 * renders as before.
 */
const SWFILE = '/sys/module/yt9215_nss/parameters/ports';
const NAMES = { 0: 'lan1', 1: 'lan2', 2: 'lan3', 3: 'wan' };
const COLORS = { lan: '#90f090', wan: '#f09090' };

function readSwitch() {
	return L.resolveDefault(fs.read(SWFILE), null).then((txt) => {
		if (txt != null)
			return txt;
		return L.resolveDefault(fs.exec('/bin/cat', [ SWFILE ]), null)
			.then((r) => (r && r.code == 0) ? r.stdout : null);
	});
}

function parse(txt) {
	return txt.trim().split(/\n/).filter((l) => l).map((l) => {
		const f = l.split(/\s+/);
		return { port: +f[0], up: f[1] == 'up', speed: +f[2], duplex: f[3],
		         rx: +f[4], tx: +f[5] };
	});
}

function speedText(p) {
	if (!p.up)
		return _('no link');
	const d = (p.duplex == 'half') ? ' (H)' : '';
	const e = E('span', { 'title': _('Speed: %d Mbit/s, Duplex: %s').format(p.speed, p.duplex) });
	e.innerText = (p.speed >= 1000) ? '%d GbE%s'.format(p.speed / 1000, d) : '%d M%s'.format(p.speed, d);
	return e;
}

return baseclass.extend({
	title: _('Port status'),

	load() {
		return readSwitch().then((txt) => {
			if (txt != null)
				return { sw: parse(txt) };
			return L.require('view.status.ports_dsa').then((dsa) => {
				this.dsa = dsa;
				return dsa.load().then((d) => ({ dsa: d }));
			});
		}).catch(() => ({ sw: [] }));
	},

	render(data) {
		if (data.dsa && this.dsa)
			return this.dsa.render(data.dsa);

		const ports = (data.sw || []).sort((a, b) => {
			const na = NAMES[a.port] || '', nb = NAMES[b.port] || '';
			return L.naturalCompare(na, nb);
		});

		return E('div', { 'style': 'display:grid;grid-template-columns:repeat(auto-fit, minmax(70px, 1fr));margin-bottom:1em' },
			ports.map((p) => {
				const name = NAMES[p.port] || 'port %d'.format(p.port);
				const role = (name == 'wan') ? 'wan' : 'lan';

				return E('div', { 'class': 'ifacebox', 'style': 'margin:.25em;min-width:70px;max-width:100px' }, [
					E('div', { 'class': 'ifacebox-head', 'style': 'font-weight:bold' }, [ name ]),
					E('div', { 'class': 'ifacebox-body' }, [
						E('img', { 'src': L.resource('icons/port_%s.svg').format(p.up ? 'up' : 'down') }),
						E('br'),
						speedText(p)
					]),
					E('div', { 'class': 'ifacebox-head', 'style': 'display:flex' }, [
						E('div', { 'style': 'flex:1;height:3px;opacity:%s;background-color:%s'.format(p.up ? 1 : 0.25, COLORS[role]) })
					]),
					E('div', { 'class': 'ifacebox-body' }, [
						E('div', { 'style': 'text-align:left;font-size:80%' }, [
							'▲ %1024.1mB'.format(p.tx), E('br'),
							'▼ %1024.1mB'.format(p.rx)
						])
					])
				]);
			}));
	}
});
