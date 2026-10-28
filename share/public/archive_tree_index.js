'use strict';
(() => {
  const root = document.getElementById('cpan-index');
  if (!root) return;
  const input = document.getElementById('module-filter');
  const body = document.getElementById('module-rows');
  const status = document.getElementById('module-status');
  const more = document.getElementById('load-more');
  let source = {
    filter: root.dataset.filter,
    tree: root.dataset.tree,
    modules: Array.from(body.querySelectorAll('tr'), row => JSON.parse(row.dataset.row)),
    complete: root.dataset.complete === 'true',
    next_after: root.dataset.nextAfter || null,
    previous_before: root.dataset.previousBefore || null
  };
  let completeCache = source.complete ? source : null;
  let revision = 0;
  let timer;
  let controller;
  let loading = false;

  function render() {
    const fragment = document.createDocumentFragment();
    for (const row of source.modules) {
      const tr = document.createElement('tr');
      for (const value of [row.name, row.version]) {
        const td = document.createElement('td');
        td.textContent = value;
        tr.append(td);
      }
      const td = document.createElement('td');
      const link = document.createElement('a');
      link.textContent = row.path;
      link.href = root.dataset.authorsUrl + row.path.split('/').map(encodeURIComponent).join('/');
      td.append(link);
      tr.append(td);
      fragment.append(tr);
    }
    body.replaceChildren(fragment);
    status.textContent = `Showing ${source.modules.length} modules${source.complete ? ' (all matches).' : '.'}`;
    more.hidden = !source.next_after;
    more.disabled = loading;
  }

  async function requestPage(append, token) {
    controller = new AbortController();
    loading = true;
    more.disabled = true;
    status.textContent = 'Loading modules…';
    const url = new URL(root.dataset.jsonUrl, document.baseURI);
    url.searchParams.set('filter', input.value);
    if (append) url.searchParams.set('after', source.next_after);
    try {
      const response = await fetch(url, {signal: controller.signal, headers: {Accept: 'application/json'}});
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const page = await response.json();
      if (token !== revision) return;
      // A branch may advance between pages. Restart rather than combine different trees.
      if (append && page.tree !== source.tree) {
        completeCache = null;
        await requestPage(false, token);
        return;
      }
      if (append) {
        page.modules = source.modules.concat(page.modules);
        page.previous_before = source.previous_before;
        page.complete = !page.previous_before && !page.next_after;
      }
      source = page;
      if (completeCache && completeCache.tree !== page.tree) completeCache = null;
      if (page.complete) completeCache = page;
      loading = false;
      render();
    } catch (error) {
      if (token !== revision || error.name === 'AbortError') return;
      loading = false;
      more.disabled = input.value !== source.filter;
      status.textContent = 'Could not load modules. Please try again.';
    }
  }

  function applyFilter(token) {
    const needle = input.value.toLowerCase();
    if (completeCache && needle.includes(completeCache.filter.toLowerCase())) {
      source = {...completeCache, filter: input.value,
        modules: completeCache.modules.filter(row => row.text.toLowerCase().includes(needle)),
        next_after: null, previous_before: null, complete: true};
      loading = false;
      render();
    } else {
      requestPage(false, token);
    }
  }

  function scheduleFilter() {
    const token = ++revision;
    clearTimeout(timer);
    if (controller) controller.abort();
    more.disabled = true;
    timer = setTimeout(() => applyFilter(token), 150);
  }
  input.addEventListener('input', scheduleFilter);
  document.getElementById('module-filter-form').addEventListener('submit', event => {
    event.preventDefault();
    scheduleFilter();
  });
  more.addEventListener('click', () => {
    if (!loading && source.next_after && input.value === source.filter) requestPage(true, ++revision);
  });
})();
