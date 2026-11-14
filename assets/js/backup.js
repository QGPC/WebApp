// Backup and restore helpers (Backups page and Restore from a Backup page).
// Needs supabase-js, config.js, auth.js and zip-2.25.0.min.js loaded first.
// A backup is one .zip file: manifest.json, data/<table>.json for every table, and files/<bucket>/<path> for
// uploaded files. When a password is set the zip is encrypted (AES-256) here in the browser, so the website's
// server never sees the password. The password is never stored anywhere by the site.
(function(){
  var FORMAT = 'guild-backup-zip-1';
  var CHUNK = 300;                       // rows sent to the database per call while restoring
  var MIME = { jpg:'image/jpeg', jpeg:'image/jpeg', png:'image/png', gif:'image/gif', webp:'image/webp', svg:'image/svg+xml',
               pdf:'application/pdf', doc:'application/msword', docx:'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
               xls:'application/vnd.ms-excel', xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
               txt:'text/plain', csv:'text/csv', json:'application/json', zip:'application/zip' };

  function pad(n){ return (n < 10 ? '0' : '') + n; }
  function today(d){ d = d || new Date(); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function fileName(kind, d){ return (kind === 'safety' ? 'guild-safety-' : 'guild-backup-') + today(d) + '.zip'; }
  function mimeOf(name){ var m = /\.([A-Za-z0-9]+)$/.exec(name || ''); return (m && MIME[m[1].toLowerCase()]) || 'application/octet-stream'; }
  function hex(buf){ var a = new Uint8Array(buf), s = ''; for (var i = 0; i < a.length; i++) s += (a[i] < 16 ? '0' : '') + a[i].toString(16); return s; }
  function sha256(buf){ return crypto.subtle.digest('SHA-256', buf).then(hex); }
  function sha256Text(text){ return sha256(new TextEncoder().encode(text)); }
  function fmtSize(n){ n = +n || 0; if (n < 1024) return n + ' bytes'; if (n < 1048576) return (n / 1024).toFixed(0) + ' KB'; return (n / 1048576).toFixed(1) + ' MB'; }
  function bad(rpc, what){ return new Error(what + (rpc && rpc.error ? ' (' + (rpc.error.message || rpc.error) + ')' : '')); }

  if (window.zip && zip.configure) zip.configure({ useWebWorkers: false });

  // ---- saving the file ----
  // Ask where to save FIRST (it must happen right after the click), then build the file, then write it.
  // Chrome and Edge let the person pick a folder or drive; other browsers get a normal download.
  function pickTarget(name){
    if (!window.showSaveFilePicker) return Promise.resolve(null);
    return window.showSaveFilePicker({ suggestedName: name, types: [{ description: 'Guild backup', accept: { 'application/zip': ['.zip'] } }] })
      .catch(function(e){ if (e && e.name === 'AbortError') throw e; return null; });
  }
  function saveBlob(blob, name, handle){
    if (handle) return handle.createWritable().then(function(w){ return w.write(blob).then(function(){ return w.close(); }); }).then(function(){ return 'chosen location'; });
    var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    setTimeout(function(){ URL.revokeObjectURL(a.href); }, 4000);
    return Promise.resolve('your Downloads folder');
  }

  // ---- making a backup ----
  // opts: { password, who, kind, onProgress(text) } -> { blob, name, counts, fileCount, skipped, bytes, encrypted }
  function make(sb, opts){
    opts = opts || {};
    var say = opts.onProgress || function(){};
    var pw = opts.password || '';
    var writer = new zip.BlobWriter('application/zip');
    var zopts = pw ? { password: pw, encryptionStrength: 3 } : {};
    var zw = new zip.ZipWriter(writer, zopts);
    var manifest = { format: FORMAT, made_at: new Date().toISOString(), made_by: opts.who || '', kind: opts.kind || 'manual',
                     encrypted: !!pw, tables: {}, files: [], skipped: [] };
    var counts = {};
    return sb.rpc('backup_tables').then(function(r){
      if (r.error) throw bad(r, 'The list of tables could not be read');
      var tables = r.data || [], i = 0;
      function nextTable(){
        if (i >= tables.length) return Promise.resolve();
        var t = tables[i++];
        say('Saving the information (' + i + ' of ' + tables.length + ')…');
        return sb.rpc('backup_table', { p_table: t }).then(function(x){
          if (x.error) throw bad(x, 'The "' + t + '" information could not be read');
          var text = JSON.stringify(x.data || []);
          counts[t] = (x.data || []).length;
          return sha256Text(text).then(function(h){
            manifest.tables[t] = { rows: counts[t], sha256: h };
            return zw.add('data/' + t + '.json', new zip.TextReader(text));
          });
        }).then(nextTable);
      }
      return nextTable();
    }).then(function(){
      return sb.rpc('backup_files');
    }).then(function(r){
      if (r.error) throw bad(r, 'The list of uploaded files could not be read');
      var files = r.data || [], i = 0;
      function nextFile(){
        if (i >= files.length) return Promise.resolve();
        var f = files[i++];
        say('Saving uploaded files (' + i + ' of ' + files.length + ')…');
        var get = f.is_public
          ? fetch(sb.storage.from(f.bucket).getPublicUrl(f.name).data.publicUrl).then(function(x){ if (!x.ok) throw new Error('HTTP ' + x.status); return x.blob(); })
          : sb.storage.from(f.bucket).download(f.name).then(function(x){ if (x.error) throw x.error; return x.data; });
        return get.then(function(blob){
          return blob.arrayBuffer().then(sha256).then(function(h){
            manifest.files.push({ bucket: f.bucket, name: f.name, size: blob.size, sha256: h });
            return zw.add('files/' + f.bucket + '/' + f.name, new zip.BlobReader(blob));
          });
        }).catch(function(e){
          manifest.skipped.push({ bucket: f.bucket, name: f.name, why: String((e && e.message) || e) });
        }).then(nextFile);
      }
      return nextFile();
    }).then(function(){
      say('Packing and locking the file…');
      return zw.add('manifest.json', new zip.TextReader(JSON.stringify(manifest, null, 1)));
    }).then(function(){ return zw.close(); }).then(function(blob){
      return { blob: blob, name: fileName(opts.kind), counts: counts, fileCount: manifest.files.length,
               skipped: manifest.skipped, bytes: blob.size, encrypted: !!pw };
    });
  }

  // ---- opening a backup file ----
  // -> { manifest, entries (by name), reader, password }
  function open(file, password){
    var reader = new zip.ZipReader(new zip.BlobReader(file));
    return reader.getEntries().then(function(list){
      var byName = {};
      list.forEach(function(e){ byName[e.filename] = e; });
      var m = byName['manifest.json'];
      if (!m) throw new Error('This does not look like a Guild backup file (no manifest).');
      return m.getData(new zip.TextWriter(), password ? { password: password } : {}).then(function(text){
        var manifest;
        try { manifest = JSON.parse(text); } catch (e) { throw new Error('The backup file is damaged (its list of contents cannot be read).'); }
        if (!manifest || String(manifest.format || '').indexOf('guild-backup-zip-') !== 0) throw new Error('This is not a Guild backup file this site can restore.');
        if (manifest.format !== FORMAT) throw new Error('This backup is from a different version of the site and cannot be restored here.');
        return { manifest: manifest, entries: byName, reader: reader, password: password || '' };
      });
    }).catch(function(e){
      var msg = String((e && e.message) || e);
      if (/password/i.test(msg) || /encrypted/i.test(msg)) throw new Error('That password does not open this backup.');
      throw e;
    });
  }

  // Read every table out of an opened backup and check each against its fingerprint.
  function readTables(opened, onProgress){
    var say = onProgress || function(){};
    var names = Object.keys(opened.manifest.tables || {}), out = {}, i = 0;
    function next(){
      if (i >= names.length) return Promise.resolve(out);
      var t = names[i++], e = opened.entries['data/' + t + '.json'];
      say('Reading the backup (' + i + ' of ' + names.length + ')…');
      if (!e) return Promise.reject(new Error('The backup file is missing the "' + t + '" information.'));
      return e.getData(new zip.TextWriter(), opened.password ? { password: opened.password } : {}).then(function(text){
        return sha256Text(text).then(function(h){
          if (h !== opened.manifest.tables[t].sha256) throw new Error('The backup file is damaged (the "' + t + '" information does not match its fingerprint).');
          out[t] = JSON.parse(text);
        });
      }).then(next);
    }
    return next();
  }

  // ---- restoring ----
  // tables: { name: [rows] } from readTables. Returns the database's answer.
  function restoreTables(sb, opened, tables, onProgress){
    var say = onProgress || function(){};
    var names = Object.keys(tables), i = 0;
    return sb.rpc('restore_stage_clear').then(function(r){
      if (r.error) throw bad(r, 'The restore could not start');
      function nextTable(){
        if (i >= names.length) return Promise.resolve();
        var t = names[i++], rows = tables[t], seq = 0;
        say('Loading the backup into the site (' + i + ' of ' + names.length + ')…');
        function nextChunk(){
          if (seq > 0 && (seq * CHUNK) >= rows.length) return Promise.resolve();
          var part = rows.slice(seq * CHUNK, (seq + 1) * CHUNK), s = seq++;
          return sb.rpc('restore_stage_put', { p_table: t, p_seq: s, p_rows: part }).then(function(x){
            if (x.error) throw bad(x, 'The backup could not be loaded');
          }).then(nextChunk);
        }
        return nextChunk().then(nextTable);
      }
      return nextTable();
    }).then(function(){
      say('Putting the information back (this is the step that changes the site)…');
      return sb.rpc('restore_site', { p_phrase: 'RESTORE', p_tables: names, p_made_at: opened.manifest.made_at || '', p_made_by: opened.manifest.made_by || '' });
    }).then(function(r){
      if (r.error) throw new Error(r.error.message || 'The restore failed.');
      return r.data;
    });
  }

  // Puts the uploaded files back. Returns { done, failed:[names] }. Never throws for one bad file.
  function restoreFiles(sb, opened, onProgress){
    var say = onProgress || function(){};
    var files = opened.manifest.files || [], i = 0, done = 0, failed = [];
    function next(){
      if (i >= files.length) return Promise.resolve({ done: done, failed: failed });
      var f = files[i++], e = opened.entries['files/' + f.bucket + '/' + f.name];
      say('Putting uploaded files back (' + i + ' of ' + files.length + ')…');
      if (!e) { failed.push(f.bucket + '/' + f.name); return next(); }
      return e.getData(new zip.BlobWriter(mimeOf(f.name)), opened.password ? { password: opened.password } : {}).then(function(blob){
        return sb.storage.from(f.bucket).upload(f.name, blob, { upsert: true, contentType: mimeOf(f.name) });
      }).then(function(x){
        if (x && x.error) failed.push(f.bucket + '/' + f.name); else done++;
      }).catch(function(){ failed.push(f.bucket + '/' + f.name); }).then(next);
    }
    return next();
  }

  window.QGPCBackup = { FORMAT: FORMAT, today: today, fileName: fileName, fmtSize: fmtSize, pickTarget: pickTarget, saveBlob: saveBlob,
                        make: make, open: open, readTables: readTables, restoreTables: restoreTables, restoreFiles: restoreFiles };
})();
