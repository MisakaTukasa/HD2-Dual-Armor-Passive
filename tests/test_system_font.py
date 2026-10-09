"""Real offscreen GDI + isolated engine mocks. Never attaches to the game."""
from __future__ import annotations

import base64
import ctypes
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from lua_runner import run, find_lua_dll
sys.path.insert(0, str(ROOT / "tools"))
from build import render_source

def verify_system_font() -> dict:
    strings = json.loads((ROOT / 'data/menu_strings.json').read_text(encoding='utf-8'))
    passives = json.loads((ROOT / 'data/passives.json').read_text(encoding='utf-8'))
    required = [text for values in strings.values() for text in values.values()]
    required.extend(p[column] for p in passives for column in ('en', 'zh', 'zh_tw'))
    literal = '{' + ','.join(json.dumps(text, ensure_ascii=False) for text in required) + '}'
    prefix = 'local SF = assert(loadstring(MOD_SOURCE))()\nlocal required = ' + literal + '\n'
    module = (ROOT / 'src/system_font.lua').read_bytes()

    harness = r'''
    local ok, why = SF.prepare(required)
    assert(ok, tostring(why))
    assert(SF.prepare({'cached'}))
    assert(SF.actual_weights.normal==400 and SF.actual_weights.chinese==700)
    assert(SF.weight_for_language('en')==700 and SF.weight_for_language('zh_cn')==700
        and SF.weight_for_language('zh_tw')==700)
    local stamp=SF.clock(); assert(stamp>0 and SF.clock()>=stamp)
    assert(not SF.glyphs[32].rgba and SF.glyphs[32].advance > 0, 'space must only advance the cursor')
    assert(SF.base64('f') == 'Zg==' and SF.base64('fo') == 'Zm8=' and SF.base64('foo') == 'Zm9v')
    assert(not pcall(SF.codes, '\240\159\152\128'))
    assert(not pcall(SF.codes, '\237\160\128'))
    assert(not pcall(SF.codes, '\224\128\128'))
    local next_id, guis, textures, bitmaps, uploads, seen = 0, {}, {}, {}, 0, {}
    local fail_destroy, fail_upload = false, false
    local function identity() next_id = next_id + 1; return next_id end
    local E = {Renderer={}, Gui={}, Material={}, World={}, IdString64={}}
    function E.Vector2(x,y) return {x=x,y=y} end
    function E.Vector3(x,y,z) return {x=x,y=y,z=z} end
    function E.Color(a,r,g,b) return {a=a,r=r,g=g,b=b} end
    function E.IdString64.from_hex(hex) return hex end
    function E.Renderer.create_resource(kind,format,w,h)
        assert(kind == 'texture' and format == 'R8G8B8A8' and w*h*4 <= 2016)
        local res = {id=identity(),width=w,height=h}; textures[res]=true; return res
    end
    function E.Renderer.update_texture_base64(res,blob,size)
        assert(textures[res] and size == res.width*res.height*4 and size <= 2016)
        assert(#blob == math.ceil(size/3)*4)
        local found = false
        for _, sizes in pairs(SF.weight_glyphs) do
          for _, glyphs in pairs(sizes) do
            for _, glyph in pairs(glyphs) do
                for _, tile in ipairs(glyph.tiles or {}) do
                    if SF.base64(tile.rgba) == blob then found = true end
                end
            end
          end
        end
        assert(found, 'upload differs from prepared RGBA')
        if fail_upload then error('simulated upload failure') end
        uploads = uploads + 1
    end
    function E.Renderer.destroy_resource(res)
        assert(textures[res])
        for gui in pairs(guis) do assert(not gui.ink or gui.ink.texture ~= res, 'texture still has GUI consumer') end
        textures[res]=nil
    end
    function E.World.create_screen_gui(world)
        local gui = {world=world,id=identity()}; guis[gui]=true; return gui
    end
    function E.World.destroy_gui(world,gui)
        assert(guis[gui] and gui.world == world)
        if fail_destroy then fail_destroy=false; error('simulated GUI destroy failure') end
        for id, owner in pairs(bitmaps) do if owner == gui then bitmaps[id]=nil end end
        guis[gui]=nil
    end
    function E.Gui.set_visible(gui,visible) assert(guis[gui] and visible) end
    function E.Gui.material(gui,name)
        assert(guis[gui] and name == 'core/performance_hud/debug')
        gui.ink = {gui=gui}; return gui.ink
    end
    function E.Material.set_resource(ink,slot,res)
        assert(guis[ink.gui] and textures[res] and slot == '3aa8b87e00000000')
        ink.texture=res
    end
    function E.Gui.bitmap_uv(gui,ink,uv0,uv1,pos,size,color)
        assert(guis[gui] and ink == "core/performance_hud/debug" and textures[gui.ink.texture])
        assert(uv0.x==0 and uv0.y==0 and uv1.x==1 and uv1.y==1 and pos.z==902)
        assert(size.x > 0 and size.y > 0 and color.a==255)
        local id=identity(); bitmaps[id]=gui; return id
    end
    function E.Gui.destroy_bitmap(gui,id) assert(bitmaps[id]==gui); bitmaps[id]=nil end
    assert(SF.api_available(E))
    assert(not SF.api_available({}))
    local text = 'English 简体中文 繁體中文'
    local function draw(world) SF.draw(E,{world=world},text,10,30,18,255,255,255,'core/performance_hud/debug') end
    draw(1); local once=uploads; draw(2); assert(uploads==once, 'texture not shared across worlds')
    local created=SF.bitmap_created; SF.begin_render(); draw(1); draw(2); SF.end_render(E)
    assert(SF.bitmap_created==created and SF.label_reused==2, 'identical labels were recreated')
    SF.begin_render()
    SF.draw(E,{world=1},text,10,30,18,255,255,255,'core/performance_hud/debug',700)
    SF.draw(E,{world=2},text,10,30,18,255,255,255,'core/performance_hud/debug',700)
    SF.end_render(E)
    assert(uploads>once, 'bold reused regular textures')
    for key in pairs(SF.textures) do assert(key:find('^700:'), 'regular texture survived bold-only view') end
    local bold_created=SF.bitmap_created
    SF.begin_render()
    SF.draw(E,{world=1},text,10,30,18,255,255,255,'core/performance_hud/debug',700)
    SF.draw(E,{world=2},text,10,30,18,255,255,255,'core/performance_hud/debug',700)
    SF.end_render(E)
    assert(SF.bitmap_created==bold_created, 'bold labels were recreated')
    SF.begin_render(); draw(1); draw(2); SF.end_render(E)
    for key in pairs(SF.textures) do assert(key:find('^400:'), 'bold texture survived regular-only view') end
    once=uploads
    assert(not SF.release(E,nil) and next(guis) and next(textures))
    SF.clear(E); assert(not next(bitmaps) and next(guis) and next(textures))
    draw(1); assert(uploads==once, 'redraw re-uploaded cached textures')
    fail_destroy=true
    assert(not pcall(SF.release,E,{1,2}))
    assert(SF.release(E,{1,2}) and not next(guis) and not next(textures) and not next(bitmaps))
    draw(1); assert(uploads > once)
    assert(SF.release(E,{1,2}))
    fail_upload=true
    assert(not pcall(draw,1))
    assert(next(textures) and not next(guis))
    assert(SF.release(E,{1,2}) and not next(textures))
    fail_upload=false
    draw(1)
    -- A vanished world owns no live engine GUI. Simulate engine teardown first.
    guis,bitmaps={},{}
    assert(SF.release(E,{2}) and not next(textures))
    local parts={}
    for code,glyph in pairs(SF.glyphs) do
        parts[#parts+1] = string.format('"%d":{"advance":%d,"left":%d,"bottom":%d,"width":%d,"height":%d,"rgba":"%s"}',
            code,glyph.advance,glyph.left,glyph.bottom,glyph.width or 0,glyph.height or 0,SF.base64(glyph.rgba or ''))
    end
    local tile_sets = {}
    for _, weight in ipairs({400,700}) do
     for _, pixel_size in ipairs({16,17,18,20,29}) do
        local glyphs, scale=SF.ensure(table.concat(required),pixel_size,weight)
        assert(scale==1)
        for code, glyph in pairs(glyphs) do
            do
                local pieces={}
                for _, tile in ipairs(SF.tiles(glyph)) do
                    assert(#tile.rgba <= 2016)
                    pieces[#pieces+1]=string.format('{"width":%d,"height":%d,"top":%d,"rgba":"%s"}',
                        tile.width,tile.height,tile.top,SF.base64(tile.rgba))
                end
                tile_sets[#tile_sets+1]=string.format('{"weight":%d,"size":%d,"code":%d,"width":%d,"height":%d,"advance":%d,"left":%d,"bottom":%d,"rgba":"%s","tiles":[%s]}',
                    weight,pixel_size,code,glyph.width or 0,glyph.height or 0,glyph.advance,glyph.left,glyph.bottom,SF.base64(glyph.rgba or ''),table.concat(pieces,','))
            end
        end
    end
    end
    RESULT_INI = string.format('{"count":%d,"glyphs":{%s},"tile_sets":[%s]}',
        SF.count,table.concat(parts,','),table.concat(tile_sets,','))
    '''

    # Same-process GDI object counts detect leaked DCs/fonts from actual rasterization.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    user = ctypes.WinDLL('user32', use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    user.GetGuiResources.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    user.GetGuiResources.restype = ctypes.c_ulong
    process = kernel.GetCurrentProcess()
    before = user.GetGuiResources(process, 0)
    result = json.loads(run('system_font_isolated', source=module, harness=(prefix+harness).encode('utf-8'))['settings'])
    after = user.GetGuiResources(process, 0)
    assert after == before, (before, after)
    needed = set(range(32,127)) | {ord(c) for text in required for c in text}
    assert set(map(int,result['glyphs'])) == needed
    total, largest = 0, 0
    for glyph in result['glyphs'].values():
        pixels = base64.b64decode(glyph['rgba'], validate=True)
        assert len(pixels) == glyph['width'] * glyph['height'] * 4 <= 2048
        total += len(pixels)
        largest = max(largest, len(pixels))
    decoded_tiles, max_tile, split_glyphs = 0, 0, 0
    for glyph in result['tile_sets']:
        full = base64.b64decode(glyph['rgba'], validate=True)
        assert len(full) == glyph['width'] * glyph['height'] * 4 <= 16384
        rebuilt = bytearray(len(full))
        covered = [False] * glyph['height']
        for tile in glyph['tiles']:
            raw=base64.b64decode(tile['rgba'], validate=True)
            assert tile['width']==glyph['width'] and len(raw)==tile['width']*tile['height']*4 <= 2016
            start=tile['top']*glyph['width']*4
            rebuilt[start:start+len(raw)]=raw
            for row in range(tile['top'],tile['top']+tile['height']):
                assert not covered[row]
                covered[row]=True
            decoded_tiles+=1; max_tile=max(max_tile,len(raw))
        assert all(covered) and bytes(rebuilt)==full
        split_glyphs+=len(glyph['tiles'])>1
    assert split_glyphs and max_tile <= 2016

    normal={(g['size'],g['code']):g for g in result['tile_sets'] if g['weight']==400}
    bold={(g['size'],g['code']):g for g in result['tile_sets'] if g['weight']==700}
    assert normal.keys()==bold.keys()
    bold_base_bytes=sum(len(base64.b64decode(g['rgba'])) for (size,_),g in bold.items() if size==18)
    bold_base_largest=max(len(base64.b64decode(g['rgba'])) for (size,_),g in bold.items() if size==18)
    changed=sum(normal[key]['rgba']!=bold[key]['rgba'] for key in normal)
    chinese_keys=[key for key in normal if key[1]>=128]
    normal_coverage=sum(sum(base64.b64decode(normal[key]['rgba'])[3::4]) for key in chinese_keys)
    bold_coverage=sum(sum(base64.b64decode(bold[key]['rgba'])[3::4]) for key in chinese_keys)
    assert changed>0 and bold_coverage>normal_coverage, 'Chinese masks are not bolder'

    english_codes={ord(c) for text in strings['en'].values() for c in text}
    english_codes|={ord(c) for passive in passives for c in passive['en']}
    english_keys=[key for key in normal if key[1] in english_codes]
    english_normal_coverage=sum(sum(base64.b64decode(normal[key]['rgba'])[3::4]) for key in english_keys)
    english_bold_coverage=sum(sum(base64.b64decode(bold[key]['rgba'])[3::4]) for key in english_keys)
    assert english_bold_coverage>english_normal_coverage, 'English masks are not bolder'

    fallbacks = []
    for index in range(1,6):
        fallback_harness=(prefix + "local family=SF.families["+str(index)+"]; SF.families={family}; local ok,why=SF.prepare(required); assert(ok,tostring(why)); assert(SF.actual_weights.normal==400 and SF.actual_weights.chinese==700); for _,weight in ipairs({400,700}) do local glyphs,scale=SF.ensure(table.concat(required),29,weight); assert(scale==1) end; RESULT_INI=SF.face").encode('utf-8')
        fallbacks.append(run('system_font_font_family', source=module, harness=fallback_harness)['settings'])
    assert fallbacks == ['Microsoft YaHei','Microsoft YaHei UI','Microsoft JhengHei','Microsoft JhengHei UI','SimSun']
    wrong_weight_harness=(r'''
    local ffi=require('ffi')
    local load=ffi.load
    ffi.load=function(name)
     local native=load(name)
     if name~='gdi32' then return native end
     return setmetatable({}, {__index=function(_,key)
      if key=='hd2dap_sf11_GetTextMetricsW' then
       return function(dc,metrics)
        local result=native[key](dc,metrics); metrics[0].weight=400; return result
       end
      end
      return native[key]
     end})
    end
    ''' + prefix+r'''
    local ok,why=SF.prepare(required)
    assert(not ok and not SF.ready and why:find('selected font weight differs',1,true),tostring(why))
    ''').encode('utf-8')
    run('system_font_wrong_selected_weight',source=module,harness=wrong_weight_harness)
    assert user.GetGuiResources(process,0)==before, 'weight mismatch leaked GDI objects'
    missing_first=(prefix+"SF.families={{name='HD2DAP intentionally unavailable',aliases={'HD2DAP intentionally unavailable'}},{name='Segoe UI',aliases={'Segoe UI'}},SF.families[4]}; local ok,why=SF.prepare(required); assert(ok,tostring(why)); assert(#SF.font_attempts==2 and SF.font_attempts[1]:find('substituted') and SF.font_attempts[2]:find('font missing')); RESULT_INI=SF.face").encode('utf-8')
    assert run('system_font_fallback',source=module,harness=missing_first)['settings']=='Microsoft JhengHei UI'
    missing_all=(prefix+"SF.families={{name='HD2DAP intentionally unavailable',aliases={'HD2DAP intentionally unavailable'}}}; local ok,why=SF.prepare(required); assert(not ok and not SF.ready and why:find('substituted')); assert(next(SF.glyphs)==nil); RESULT_INI='safe failure'").encode('utf-8')
    assert run('system_font_missing_fonts',source=module,harness=missing_all)['settings']=='safe failure'
    assert user.GetGuiResources(process,0)==before

    cases = ('settings_missing','language_auto_en','pagination_keyboard','pagination_mouse',
             'gui_deferred_cleanup','gui_removed_world','gui_failed_cleanup')
    candidate = render_source('release')
    standard_harness = (ROOT / 'tests/offline_runtime.lua').read_bytes()
    anchor = b'ffi.load = function(name)\n'
    assert standard_harness.count(anchor) == 1
    standard_harness = standard_harness.replace(anchor, anchor + b'    if name == "gdi32" then return real_load(name) end\n')
    for case in cases:
        run(case, source=candidate, harness=standard_harness)

    integration_api = r'''
    local sf_guis, sf_textures, sf_uploads, sf_bitmaps = {}, {}, 0, 0
    local sf_menu_counts = {}
    local function count_bitmap_handles() local n=0; for _,entry in pairs(ctx.gui_entries) do if entry.kind=="bitmap" then n=n+1 end end; return n end
    local create_gui = s3d.World.create_screen_gui
    local destroy_gui = s3d.World.destroy_gui
    s3d.World.create_screen_gui = function(world, ...)
        local gui = create_gui(world, ...); sf_guis[gui] = true; return gui
    end
    s3d.World.destroy_gui = function(world, gui)
        assert(sf_guis[gui] and gui.world == world)
        for handle, entry in pairs(ctx.gui_entries) do
            if entry.instance == gui then ctx.gui_entries[handle]=nil end
        end
        destroy_gui(world, gui); sf_guis[gui] = nil
    end
    s3d.Gui.material = function(gui, name)
        assert(sf_guis[gui] and name == 'core/performance_hud/debug')
        gui.ink = {gui=gui}; return gui.ink
    end
    s3d.Renderer = {
        create_resource = function(kind, format, w, h)
            assert(kind == 'texture' and format == 'R8G8B8A8' and w*h*4 <= 2016)
            local resource = {width=w,height=h}; sf_textures[resource]=true; return resource
        end,
        update_texture_base64 = function(resource, blob, size)
            assert(sf_textures[resource] and size == resource.width*resource.height*4 and size <= 2016)
            assert(#blob == math.ceil(size/3)*4); sf_uploads=sf_uploads+1
        end,
        destroy_resource = function(resource)
            assert(sf_textures[resource])
            for gui in pairs(sf_guis) do
                assert(not gui.ink or gui.ink.texture ~= resource, 'live GUI still consumes texture')
            end
            sf_textures[resource]=nil
        end,
    }
    s3d.Material.set_resource = function(ink, slot, resource)
        assert(sf_guis[ink.gui] and sf_textures[resource])
        assert(slot.hash == '3aa8b87e00000000' and slot.frame == ctx.frame)
        ink.texture=resource
    end
    s3d.Gui.bitmap_uv = function(gui, ink, uv0, uv1, pos, size, color)
        assert(sf_guis[gui] and ink == 'core/performance_hud/debug' and sf_textures[gui.ink.texture])
        assert(uv0.x==0 and uv0.y==0 and uv1.x==1 and uv1.y==1 and pos.z==902)
        sf_bitmaps=sf_bitmaps+1
        return gui_entry('bitmap', gui, ink, uv0, uv1, pos, size, color)
    end
    s3d.Gui.destroy_bitmap = function(gui, handle)
        assert(ctx.gui_entries[handle] and ctx.gui_entries[handle].instance == gui)
        ctx.gui_entries[handle]=nil
    end
    '''
    integration_case = r'''
    elseif CASE == "system_font_menu" then
        open_menu(); equal(M.display_language, 'zh_cn')
        local function check_weight(weight)
            assert(next(HD2DAP_TEST_FONT.textures), 'no font textures')
            for key in pairs(HD2DAP_TEST_FONT.textures) do
                assert(key:find('^'..weight..':'), 'menu language used another weight')
            end
        end
        check_weight(700)
        assert(sf_uploads > 0 and sf_bitmaps > 0 and next(sf_textures))
        sf_menu_counts.zh_cn=count_bitmap_handles()
        click('traditional'); equal(M.menu_language, 'zh_tw'); equal(M.display_language, 'zh_tw')
        check_weight(700)
        assert(ctx.files[INI]:find('menu_language=zh_tw', 1, true))
        sf_menu_counts.zh_tw=count_bitmap_handles()
        click('english'); equal(M.menu_language, 'en'); equal(M.display_language, 'en')
        check_weight(700)
        sf_menu_counts.en=count_bitmap_handles()
        click('simplified'); equal(M.menu_language, 'zh_cn'); equal(M.display_language, 'zh_cn')
        check_weight(700)
        local prior=sf_bitmaps
        click('prev'); sf_menu_counts.page_wrap_created=sf_bitmaps-prior
        assert(sf_menu_counts.page_wrap_created>0 and sf_menu_counts.page_wrap_created<sf_menu_counts.zh_cn, 'page rebuilt unchanged labels')
        click('next'); equal(ctx.writes, 0)
        for texture in pairs(sf_textures) do
            local consumed=false
            for gui in pairs(sf_guis) do
                if gui.ink and gui.ink.texture==texture then
                    for _,entry in pairs(ctx.gui_entries) do
                        if entry.kind=='bitmap' and entry.instance==gui then consumed=true end
                    end
                end
            end
            assert(consumed, 'GPU cache retained an unused glyph')
        end

        tap('escape')
        assert(not next(sf_guis) and not next(sf_textures) and not next(ctx.gui_entries), 'close leaked render consumers')
        local previous_uploads=sf_uploads
        open_menu(); equal(M.display_language, 'zh_cn'); assert(sf_uploads > previous_uploads)
        tap('escape'); assert(not next(sf_guis) and not next(sf_textures) and not next(ctx.gui_entries))
        RESULT_INI=string.format('{"zh_cn":%d,"zh_tw":%d,"en":%d,"page_wrap_created":%d}',sf_menu_counts.zh_cn,sf_menu_counts.zh_tw,sf_menu_counts.en,sf_menu_counts.page_wrap_created)
    '''
    load_anchor = b'assert(loadstring(MOD_SOURCE, "@expanded/mod.lua"))()'
    case_anchor = b'elseif CASE == "measure_menu" then'
    assert standard_harness.count(load_anchor) == standard_harness.count(case_anchor) == 1
    integration_harness = standard_harness.replace(load_anchor, integration_api.encode()+b'\n'+load_anchor)
    integration_harness = integration_harness.replace(case_anchor, integration_case.encode()+b'\n'+case_anchor)
    integration_harness=integration_harness.replace(b'RESULT_INI = ctx.files[INI]',b'if CASE ~= "system_font_menu" then RESULT_INI = ctx.files[INI] end')
    integration_result=run('system_font_menu', settings='settings_version=1\nmenu_hotkey=f9\nmenu_language=zh_cn\n',
        source=candidate+b'\nHD2DAP_TEST_FONT=SF\n', harness=integration_harness)
    assert b'HD2DAP_TEST_FONT' not in candidate, 'test observer reached packaged source'
    menu_counts=json.loads(integration_result['settings'])
    assert user.GetGuiResources(process, 0) == before, 'candidate integration leaked GDI objects'
    missing_case = r'''
    elseif CASE == "system_font_all_fonts_missing" then
        open_menu(); equal(M.display_language,'en'); equal(M.menu_language,'zh_tw')
        assert(M.language_status:find('substituted') and sf_uploads==0)
        assert(ctx.files[INI]:find('menu_language=zh_tw',1,true))
        tap('escape'); assert(not next(sf_guis) and not next(sf_textures) and not next(ctx.gui_entries))
    '''
    a=candidate.index(b'SF.families = {')
    b=candidate.index(b'\n}\n',a)+3
    no_fonts=candidate[:a]+b"SF.families = {{name='HD2DAP intentionally unavailable',aliases={'HD2DAP intentionally unavailable'}}}\n"+candidate[b:]
    no_font_harness=integration_harness.replace(case_anchor,missing_case.encode()+b'\n'+case_anchor)
    run('system_font_all_fonts_missing',settings='settings_version=1\nmenu_hotkey=f9\nmenu_language=zh_tw\n',source=no_fonts,harness=no_font_harness)
    assert user.GetGuiResources(process,0)==before


    report = {'glyph_count':result['count'],'base_raster_bytes':total,'largest_base_raster_bytes':largest,'decoded_tiles':decoded_tiles,'largest_upload_bytes':max_tile,'split_glyphs':split_glyphs,
              'language_weights':{'en':700,'zh_cn':700,'zh_tw':700},'weights_independently_rasterized':True,
              'all_menu_languages_bold':True,
              'english_normal_alpha_sum':english_normal_coverage,'english_bold_alpha_sum':english_bold_coverage,
              'changed_bold_glyph_size_pairs':changed,'chinese_normal_alpha_sum':normal_coverage,'chinese_bold_alpha_sum':bold_coverage,
              'bold_base_raster_bytes':bold_base_bytes,'largest_bold_base_raster_bytes':bold_base_largest,
              'prepared_base_raster_bytes':total+bold_base_bytes,
              'outline':False,'text_passes':1,'weight_cache_switching_verified':True,'wrong_selected_weight_rejected':True,
              'gdi_objects_before':before,'gdi_objects_after':after,
              'mock_lifecycle_checks':'two worlds, reuse, deferred cleanup, retry, reopen, failed upload, vanished world',
              'fallback_families':fallbacks,'missing_and_substituted_font_checks':True,'decoder_buffer_margin_bytes':32,'mock_bitmap_counts':menu_counts,'actual_pixel_sizes':[16,17,18,20,29],'candidate_runtime_cases':list(cases) + ['system_font_menu', 'system_font_all_fonts_missing'],
              'mock_menu_integration':'all three language weights, preference persistence, pagination, close, reopen, consumer cleanup',
              'preview_pixel_orientation':'top-down rows; Gui.bitmap_uv top-left (0,0), bottom-right (1,1)',
              'real_engine_texture_upload':False,'live_validated':False}
    return report


class SystemFontTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "win32" and find_lua_dll(), "requires Win64 GDI and standalone LuaJIT")
    def test_actual_gdi_tiles_fallbacks_and_renderer_lifecycle(self):
        report = verify_system_font()
        self.assertEqual(report["language_weights"], {"en": 700, "zh_cn": 700, "zh_tw": 700})
        self.assertLessEqual(report["largest_upload_bytes"], 2016)
        self.assertEqual(report["gdi_objects_before"], report["gdi_objects_after"])


if __name__ == "__main__":
    unittest.main()
