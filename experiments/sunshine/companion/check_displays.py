"""Coordinate and protocol regressions; no pixels, remote input or socket access."""
import json
import unittest
from display_targets import Monitor,capture_catalog,encode_catalog,native_relative_inside,source_point,virtual_point

class Outputs(unittest.TestCase):
    def test_catalog_is_primary_first_and_does_not_accept_ambiguous_sources(self):
        screens=[Monitor("left",(-1920,0,0,1080),False),Monitor("main",(0,0,1920,1080),True)]
        rows=[dict(display_name=s.name,device_id="{00000000-0000-0000-0000-%012d}"%i,info=dict(primary=s.primary))
              for i,s in enumerate(screens)]
        log=lambda: "Currently available display devices: "+json.dumps(rows)
        self.assertEqual([m.name for m in capture_catalog(log(),screens)],["main","left"])
        rows.append(rows[0])
        self.assertEqual(len(capture_catalog(log(),screens)),1)
        rows.append(rows[1]); self.assertEqual(capture_catalog(log(),screens),[])

    def test_old_versions_and_secrets_unchanged(self):
        packet=b'SCH2'+bytes(88)+b'3.14'+bytes(28)
        ext=encode_catalog(packet,[1,2,3],2)
        self.assertEqual(len(ext),124); self.assertEqual(ext[:116],packet[:116])
        self.assertEqual(ext[116:],b'MON1\x03\x02\x00\x00')
        nonempty=packet[:114]+b'123456789\x00'
        self.assertEqual(encode_catalog(nonempty,[1,2],1),nonempty)
        self.assertEqual(encode_catalog(packet,[1],1),packet)

    def test_relative_mouse_stays_native_in_selected_output_interior(self):
        left=(-1920,0,0,1080)
        self.assertTrue(native_relative_inside(left,-900,500,-18,46))
        self.assertFalse(native_relative_inside(left,-1,500,2,0))
        self.assertFalse(native_relative_inside(left,20,300,-10,1))
        self.assertFalse(native_relative_inside(left,-600,4,1,-5))

    def test_letterbox_and_negative_origin_pixel_centres(self):
        area=(-1920,0,3840,1080); left=(-1920,0,0,1080); main=(0,0,1920,1080)
        for rect in (left,main,(1920,0,3840,1080)):
            for x,y in ((0,0),(32768,32768),(65535,65535)):
                px,py=source_point(rect,(960,540),x,y)
                wx,wy=virtual_point(area,px,py)
                self.assertEqual((wx*5760//65536-1920,wy*1080//65536),(px,py))
        portrait=(-1080,-800,0,1120)
        self.assertIsNone(source_point(portrait,(960,540),0,32768))
        x,y=source_point(portrait,(960,540),32768,32768)
        self.assertLessEqual(abs(x+540),2); self.assertLessEqual(abs(y-160),2)

if __name__=="__main__": unittest.main()
