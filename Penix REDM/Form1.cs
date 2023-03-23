using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Penix_REDM
{
    public partial class Form1 : Form
    {
        public Form1()
        {
            InitializeComponent();
        }


        public static void Execute()
        {
            using (StreamWriter streamWriter = new StreamWriter(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", true))
                streamWriter.WriteLine("");
            Form1.c1();
        }

        public static void c1()
        {
            using (StreamWriter streamWriter = new StreamWriter(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", true))
                streamWriter.WriteLine("if GetCurrentResourceName() == \"spawnmanager\" then");
            Form1.c2();
        }


        public static void c2()
        {
            string empty = string.Empty;
            string str1 = string.Empty;
            OpenFileDialog openFileDialog = new OpenFileDialog();
            openFileDialog.InitialDirectory = "c:\\";
            openFileDialog.Filter = "lua files (*.lua)|*.lua";
            openFileDialog.FilterIndex = 0;
            openFileDialog.RestoreDirectory = true;
            if (openFileDialog.ShowDialog() != DialogResult.OK)
                return;
            str1 = openFileDialog.FileName;
            try
            {
                Stream stream = openFileDialog.OpenFile();
                StreamReader streamReader = new StreamReader(stream);
                using (new StreamReader(stream))
                {
                    string str2;
                    while ((str2 = streamReader.ReadLine()) != null)
                    {
                        using (StreamWriter streamWriter = new StreamWriter(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", true))
                            streamWriter.WriteLine(str2);
                    }
                    Form1.c3();
                }
            }
            catch (IOException ex)
            {
                int num = (int)MessageBox.Show(ex.Message);
            }
        }

        public static void c3()
        {
            using (StreamWriter streamWriter = new StreamWriter(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", true))
                streamWriter.WriteLine("end");
            Form1.c4();
        }

        public static void c4()
        {
            using (StreamWriter streamWriter = new StreamWriter(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", true))
                streamWriter.WriteLine("");
            MessageBox.Show("Files Loaded", "Penix");
        }
        public static void CustomExecute()
        {
            using (StreamWriter streamWriter = new StreamWriter(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", true))
                streamWriter.WriteLine("");
            Form1.c1();
        }

        private void siticoneButton1_Click(object sender, EventArgs e)
        {
            File.Delete(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua");
            File.WriteAllBytes(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", Penix_REDM.Properties.Resources.scheduler);

            File.Delete(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua");
            File.WriteAllBytes(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", Penix_REDM.Properties.Resources.schedulerphoenixv1);
            MessageBox.Show("Files Loaded", "Penix");
        }

        private void siticoneButton2_Click(object sender, EventArgs e)
        {
            File.Delete(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua");
            File.WriteAllBytes(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", Penix_REDM.Properties.Resources.scheduler);

            Form1.CustomExecute();
        }

        private void siticoneButton3_Click(object sender, EventArgs e)
        {
            File.Delete(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua");
            File.WriteAllBytes(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\AppData\\Local\\RedM\\RedM.app\\citizen\\scripting\\lua\\scheduler.lua", Penix_REDM.Properties.Resources.scheduler);
            MessageBox.Show("Files Reset", "Penix");
        }
    }
}
